{
  title: "Workato CICD for Github V3", 

  secure_tunnel: true,

  connection: {
    fields: [{
      name: "connection_type",
      label: "Connection type",
      hint: "Select if GitHub is hosted on-prem or in cloud.",
      optional: false,
      control_type: "select",
      pick_list: [ %w[GitHub.com cloud], %w[On\ Premise onpremise] ]
    },{
      ngIf: "input.connection_type == 'onpremise'",
      name: "hostname",
      label: "GitHub hostname",
      control_type: "url",
      hint: "GitHub hostname for authentication and API interactions. Enter your on-prem enterprise edition hostname.",
      optional: false,
    },{
      name: "client_id",
      label: "Client ID",
      optional: false,
      hint: "<a href=\"https://docs.github.com/en/developers/apps/building-oauth-apps/creating-an-oauth-app\" target=\"_blank\">Learn more</a> about setting up OAuth 2.0 for your GitHub account."
    },{
      name: "client_secret",
      label: "Client secret",
      optional: false,
      control_type: "password"
    },{
      name: "base_branch_name",
      label: "Base branch name",
      hint: "Select the name of your base branch.",
      optional: false,
      control_type: "select",
      pick_list: [ %w[Main main], %w[Master master] ],
      default: "main"
    },{
      name: "repo_owner",
      label: "Repository owner name",
      hint: "E.g., octocat is owner for repository https://github.com/octocat/hello-world.",
      optional: false,
      control_type: "text"
    }],

    authorization: {
      type: "oauth2",

      authorization_url: lambda do |connection|
        github_hostname = connection["connection_type"] == "cloud" ? "https://github.com" : "#{connection["hostname"]}"
        "#{github_hostname}/login/oauth/authorize?scope=repo"
      end,

      token_url: lambda do |connection|
        github_hostname = connection["connection_type"] == "cloud" ? "https://github.com" : "#{connection["hostname"]}"
        "#{github_hostname}/login/oauth/access_token"
      end,

      client_id: lambda do |connection|
        connection["client_id"]
      end,

      client_secret: lambda do |connection|
        connection["client_secret"]
      end,   

      acquire: lambda do |connection, auth_code|
        github_hostname = connection["connection_type"] == "cloud" ? "https://github.com" : "#{connection["hostname"]}"
        "#{github_hostname}/login/oauth/access_token"        
        response = post("#{github_hostname}/login/oauth/access_token").
          payload(
            client_id: "#{connection["client_id"]}",
            client_secret: "#{connection["client_secret"]}",
            code: auth_code,
            redirect_uri: "https://www.workato.com/oauth/callback"
          ).headers(Accept: "application/json")
        [{ # This hash is for your tokens
          access_token: response["access_token"]
        }]
      end,

      detect_on: [401],

      refresh_on: [401],

      apply: lambda do |connection, access_token|
        headers(Authorization: "token #{access_token}",
          Accept: "application/vnd.github.v3+json")
      end,       
    },

    base_uri: lambda do |connection|
      if connection["connection_type"] == "cloud"
        "https://api.github.com/"
      else 
        "#{connection["hostname"]}/api/v3/"
      end
    end,     
  },

  test: lambda do |connection|
    get("repositories")
  end,

  object_definitions: {
    custom_action_input: {
      fields: lambda do |connection, config_fields|
        verb = config_fields['verb']
        input_schema = parse_json(config_fields.dig('input', 'schema') || '[]')
        data_props =
          input_schema.map do |field|
            if config_fields['request_type'] == 'multipart' &&
              field['binary_content'] == 'true'
              field['type'] = 'object'
              field['properties'] = [
                { name: 'file_content', optional: false },
                { name: 'content_type', default: 'text/plain', sticky: true },
                { name: 'original_filename', sticky: true }
              ]
            end
            field
          end
        data_props = call('make_schema_builder_fields_sticky', data_props)
        input_data =
          if input_schema.present?
            if input_schema.dig(0, 'type') == 'array' &&
              input_schema.dig(0, 'details', 'fake_array')
              { name: 'data', type: 'array', of: 'object', properties: data_props.dig(0, 'properties') }
            else
              { name: 'data', type: 'object', properties: data_props }
            end
          end
        [{
          name: 'path',
          hint: 'Base URI is <b>' \
            "#{connection['base_uri']}" \
            '</b> - path will be appended to this URI. Use absolute URI to ' \
            'override this base URI.',
          optional: false
        },
          if %w[post put patch].include?(verb)
            {
              name: 'request_type',
              default: 'json',
              sticky: true,
              extends_schema: true,
              control_type: 'select',
              pick_list: [
                ['JSON request body', 'json'], ['URL encoded form', 'url_encoded_form'],
                ['Mutipart form', 'multipart'], ['Raw request body', 'raw']
              ]
            }
          end,
          {
            name: 'response_type',
            default: 'json',
            sticky: false,
            extends_schema: true,
            control_type: 'select',
            pick_list: [['JSON response', 'json'], ['Raw response', 'raw']]
          },
          if %w[get options delete].include?(verb)
            {
              name: 'input',
              label: 'Request URL parameters',
              sticky: true,
              add_field_label: 'Add URL parameter',
              control_type: 'form-schema-builder',
              type: 'object',
              properties: [
                { name: 'schema', sticky: input_schema.blank?, extends_schema: true },
                input_data
              ].compact
            } else {
              name: 'input',
              label: 'Request body parameters',
              sticky: true,
              type: 'object',
              properties:
              if config_fields['request_type'] == 'raw'
                [{ name: 'data', sticky: true, control_type: 'text-area', type: 'string' }]
              else
                [{
                  name: 'schema',
                  sticky: input_schema.blank?,
                  extends_schema: true,
                  schema_neutral: true,
                  control_type: 'schema-designer',
                  sample_data_type: 'json_input',
                  custom_properties:
                  if config_fields['request_type'] == 'multipart'
                    [{
                      name: 'binary_content',
                      label: 'File attachment',
                      default: false,
                      optional: true,
                      sticky: true,
                      control_type: 'checkbox',
                      type: 'boolean',
                      render_input: 'boolean_conversion',
                      parse_output: 'boolean_conversion'
                    }]
                  end
                },
                  input_data
                ].compact
              end
            }
          end,
          {
            name: 'request_headers',
            sticky: false,
            extends_schema: true,
            control_type: 'key_value',
            empty_list_title: 'Does this HTTP request require headers?',
            empty_list_text: 'Refer to the API documentation and add ' \
              'required headers to this HTTP request',
            item_label: 'Header',
            type: 'array',
            of: 'object',
            properties: [ {name: 'key'}, {name: 'value'} ]
          },
          unless config_fields['response_type'] == 'raw'
            {
              name: 'output',
              label: 'Response body',
              sticky: true,
              extends_schema: true,
              schema_neutral: true,
              control_type: 'schema-designer',
              sample_data_type: 'json_input'
            }
          end,
          {
            name: 'response_headers',
            sticky: false,
            extends_schema: true,
            schema_neutral: true,
            control_type: 'schema-designer',
            sample_data_type: 'json_input'
          }
        ].compact
      end
    },

    custom_action_output: {
      fields: lambda do |_connection, config_fields|
        response_body = { name: 'body' }
        [
          if config_fields['response_type'] == 'raw'
            response_body
          elsif (output = config_fields['output'])
            output_schema = call('format_schema', parse_json(output))
            if output_schema.dig(0, 'type') == 'array' &&
              output_schema.dig(0, 'details', 'fake_array')
              response_body[:type] = 'array'
              response_body[:properties] = output_schema.dig(0, 'properties')
            else
              response_body[:type] = 'object'
              response_body[:properties] = output_schema
            end
            response_body
          end,
          if (headers = config_fields['response_headers'])
            header_props = parse_json(headers)&.map do |field|
              if field[:name].present?
                field[:name] = field[:name].gsub(/\W/, '_').downcase
              elsif field['name'].present?
                field['name'] = field['name'].gsub(/\W/, '_').downcase
              end
              field
            end
            { name: 'headers', type: 'object', properties: header_props }
          end
        ].compact
      end
    },

    release_details_output: {
      fields: lambda do |connection, _| [
        { name: "release_name", label: "Release name" },
        { name: "release_version", label: "Release version" },
        { name: "id", label: "ID", hint: "Project or manifest ID." },
        { name: "release_package", label: "Release package ID" },
        { name: "release_refs", label: "Release references" },
        { name: "release_mode", label: "Release mode" }           
      ]
      end 
    }
  },

  actions: {
    custom_action: {
      subtitle: "Build your own GitHub action with a HTTP request",

      description: lambda do |object_value, _object_label|
        "<span class='provider'> #{object_value[:action_name] || 'Custom action'}</span> in <span class='provider'>CICD for GitHub</span>"
      end,

      help: {
        body: "Build your own GitHub action with a HTTP request. The request will be authorized with your CICD for GitHub connection. Refer the <b>API doc</b> under in your application"
      },

      config_fields: [
        {
          name: "action_name",
          hint: "Give this action you're building a descriptive name, e.g. create record, get record",
          default: "Custom action",
          optional: false,
          schema_neutral: true
        },
        {
          name: 'verb',
          label: 'Method',
          hint: 'Select HTTP method of the request',
          optional: false,
          control_type: 'select',
          pick_list: %w[get post put patch options delete]
          .map { |verb| [verb.upcase, verb] }
        }
      ],

      input_fields: lambda do |object_definition|
        object_definition['custom_action_input']
      end,

      execute: lambda do |_connection, input|
        verb = input['verb']
        error("#{verb.upcase} not supported") if %w[get post put patch options delete].exclude?(verb)
        path = input['path']
        data = input.dig('input', 'data') || {}
        if input['request_type'] == 'multipart'
          data = data.each_with_object({}) do |(key, val), hash|
            hash[key] =
              if val.is_a?(Hash)
                [val[:file_content], val[:content_type], val[:original_filename]]
              else
                val
              end
          end
        end
        request_headers = input['request_headers']&.each_with_object({}) do |item, hash|
          hash[item['key']] = item['value']
        end || {}
        request = case verb
        when 'get'
          get(path, data)
        when 'post'
          if input['request_type'] == 'raw'
            post(path).request_body(data)
          else
            post(path, data)
          end
        when 'put'
          if input['request_type'] == 'raw'
            put(path).request_body(data)
          else
            put(path, data)
          end
        when 'patch'
          if input['request_type'] == 'raw'        
            patch(path).request_body(data)
          else
            patch(path, data)
          end
        when 'options'
          options(path, data)
        when 'delete'
          delete(path, data)
        end.headers(request_headers)
        request = case input['request_type']
        when 'url_encoded_form'
          request.request_format_www_form_urlencoded
        when 'multipart'
          request.request_format_multipart_form
        else
          request
        end
        response = 
        if input['response_type'] == 'raw'
          request.response_format_raw
        else
          request
        end
        .after_error_response(/.*/) do |code, body, headers, message|
          error({ code: code, message: message, body: body, headers: headers }.to_json)
        end
        response.after_response do |_code, res_body, res_headers| {
          body: res_body ? call('format_response', res_body) : nil,
          headers: res_headers
        }
        end
      end,

      output_fields: lambda do |object_definition|
        object_definition['custom_action_output']
      end
    },

    get_release: {
      title: "Get release",
      subtitle: "Get release from GitHub",

      help: "Returns a specificed release from GitHub repo. Use the published release version for a manual deployment.",

      description: lambda do |input| 
        "Get <span class='provider'>release</span> from " \
          "GitHub <span class='provider'>#{input["repo_name"]}</span>"
      end,

      input_fields: lambda do |object_definitions|
        [
          {
            name: "repo_name",
            label: "Repository name",
            hint: "GitHub repository name.",
            optional: false
          },
          {
            name: "tag_name",
            label: "Release tag name",
            hint: "Release tag name or version for the release.",
            optional: false,
          }          
        ]
      end,

      execute: lambda do |connection, input|

        # https://docs.github.com/en/rest/reference/repos#get-a-release-by-tag-name
        get("repos/#{connection["repo_owner"]}/#{input["repo_name"]}/releases/tags/#{input["tag_name"]}")        
        .after_error_response(/.*/) do |_code, body, _, message|
          error("#{message}: #{body}") 
        end
        .after_response do |code, body, headers|
          output = {}
          output["release_name"] = body["name"].to_s
          output["release_version"] = body["tag_name"].to_s

          if call("valid_yaml", body["body"])
            release_details = workato.parse_yaml(body["body"])
            if release_details.has_key?("id")
              output["id"] = release_details["id"].to_s 
            elsif release_details.has_key?("manifest") # backward compatible
              output["id"] = release_details["manifest"].to_s 
            end            
            output["release_package"] = release_details["package"].to_s || ""
            #output["release_refs"] = release_details["refs"].to_s || ""
            #output["release_mode"] = release_details["release_mode"].to_s || ""
          end

          output
        end

      end, # execute.end

      output_fields: lambda do |object_definitions|
        object_definitions["release_details_output"]     
      end

    },

    create_release: {
      title: "Create release",
      subtitle: "Create release in GitHub",

      help: "Uses pull request commit message to automatically determine release version, release notes, and creates a new release.",

      description: lambda do |input| 
        "Create <span class='provider'>release</span> in " \
          "GitHub <span class='provider'>#{input["repo_name"]}</span>"
      end,

      input_fields: lambda do |object_definitions|
        [
          {
            name: "repo_name",
            label: "Repository name",
            hint: "GitHub repository name.",
            optional: false
          },
          {
            name: "release_name",
            label: "Release name",
            hint: "Give a name to the release.",
            optional: false
          },
          {
            name: "release_version",
            label: "Release version",
            hint: "Release version",
            optional: false
          },
          {
            name: "release_log",
            label: "Release log",
            hint: "Release log",
            optional: true
          },
          {
            name: "generate_release_notes",
            label: "Generate Release Notes",
            hint: "Generate Release Notes. Allowed values: true or false",
            optional: true
          },
        ]
      end,

      execute: lambda do |connection, input|
        call("create_new_release", connection, input)

      end, # execute.end

      output_fields: lambda do |connection|
        [
          {
            control_type: "text",
            label: "Release version",
            type: "string",
            name: "release_version"
          },          
          {
            control_type: "text",
            label: "Release link",
            type: "string",
            name: "release_url"
          },
          {
            control_type: "text",
            label: "Release log",
            type: "string",
            name: "release_log"
          },
        ]        
      end       

    },

    create_file_blob: {
      title: "Create blob",
      subtitle: "Create blob for files in GitHub",

      help: "A Git blob (binary large object) is the object type used to store the contents of each file in a repository. ",

      description: lambda do |input| 
        "Create <span class='provider'>blob</span> in " \
          "GitHub <span class='provider'>#{input["repo_name"]}</span>"
      end,

      input_fields: lambda do |object_definitions| 
        [
          {
            name: "repo_name",
            label: "Repository name",
            hint: "Target GitHub repository name to create blob for a given file.",
            optional: false
          },          
          {
            name: "files",
            label: "Files",
            hint: "Files to be stored as blobs in GitHub repo. Contents will be base64 encoded.",
            optional: false,
            type: "array",
            of: "object",
            properties: [
              {
                control_type: "text",
                label: "File path",
                name: "file_path",
                type: "string",
                optional: false
              },
              {
                control_type: "text",
                label: "File content",
                name: "file_content",
                type: "string",
                optional: false
              }              
            ]
          }
        ]
      end,

      execute: lambda do |connection, input, eis, eos| 

        # Pre-processing of the data. 
        # For multithreading, we need to create an array of requests which we do over here.
        number_of_batches = input['files'].size
        batches = input['files'].map do |file|
          # Create a file blob in GitHub DB
          # https://docs.github.com/en/rest/reference/git#create-a-blob
          post("repos/#{connection["repo_owner"]}/#{input["repo_name"]}/git/blobs", {
            content: file["file_content"].encode_base64,
            encoding: "base64"
          })
        end

        # Sending of the requests in simultaneously using the parallel method
        # Adjust rpm as per your GitHub rate limit - refer GitHub docs for more details
        # https://docs.github.com/en/rest/overview/resources-in-the-rest-api#rate-limiting
        results = parallel(batches, threads: 20, rpm: 60)

        # Post-processing
        # Boolean to tell the user that all records were successful        
        success = results[0]
        # An array of all the responses for successful records
        files_staged = []
        results[1].each_with_index do |item, index|
          next unless item
          success_file = {
            file_path: input["files"][index]["file_path"],
            sha: item["sha"]
          }
          files_staged << success_file
        end
        # Collecting all the failed records into an array
        files_failed = []
        results[2].each_with_index do |item, index|
          next unless item 
          failed_file = {
            code: item,
            file: input["files"][index]["file_path"]
          }
          files_failed << failed_file
        end

        {
          success: success,
          files_staged: files_staged,
          files_failed: files_failed          
        }

      end,

      output_fields: lambda do |connection|
        [
          {
            control_type: "text",
            label: "Success",
            type: "boolean",
            name: "success"
          },
          {
            label: "Staged files",
            name: "files_staged",
            type: "array",
            of: "object",
            properties: [
              {
                control_type: "text",
                name: "file_path",
                label: "File path",
                type: "string"
              },
              {
                control_type: "text",
                name: "sha",
                label: "File SHA",
                type: "string"
              }              
            ]
          },
          {
            label: "Failed files",
            name: "files_failed",
            type: "array",
            of: "object",
            properties: [
              {
                control_type: "text",
                name: "code",
                label: "Error code",
                type: "string"
              },
              {
                control_type: "text",
                name: "file_path",
                label: "File path",
                type: "string"
              }               
            ]            
          }          
        ]        
      end
    },

    commit_new_branch: {
      title: "Commit branch",
      subtitle: "Commit new branch in GitHub",

      help: "A Git commit is a snapshot of the hierarchy (Git tree) and the contents of the files (Git blob) in a Git repository.",

      description: lambda do |input| 
        "Commit <span class='provider'>branch</span> in " \
          "GitHub <span class='provider'>#{input["repo_name"]}</span>"
      end,

      input_fields: lambda do |object_definitions| 
        [
          {
            name: "repo_name",
            label: "Repository name",
            hint: "Target GitHub repository.",
            optional: false
          },
          {
            control_type: "text",
            label: "Branch reference",
            type: "string",
            name: "branch_reference",
            optional: false,
            hint: "The new branch reference."
          }, 
          {
            control_type: "text",
            label: "Branch reference SHA",
            type: "string",
            name: "branch_reference_sha",
            optional: false,
            hint: "The SHA1 value for new branch reference."
          },  
          {
            name: "git_tree",
            type: "array",
            of: "object",
            label: "Git blob list",
            optional: false,
            list_mode_toggle: true,
            list_mode: "dynamic", 
            hint: "A Git tree object creates the hierarchy between files in a Git repository. Use blob list to populate this object.",
            properties: [
              {
                control_type: "text",
                label: "File path",
                name: "path",
                type: "string",
                optional: false,
                hint: "The path for referenced file in the tree."
              },
              {
                control_type: "text",
                label: "File mode",
                name: "mode",
                type: "string",
                optional: false,
                default: "100644",
                hint: "The file mode; one of 100644 for file (blob), 100755 for executable (blob), 040000 for subdirectory (tree), 160000 for submodule (commit), or 120000 for a blob that specifies the path of a symlink."
              },
              {
                control_type: "text",
                label: "File type",
                name: "type",
                type: "string",
                optional: false,
                default: "blob",
                hint: "Either blob, tree, or commit."
              },
              {
                control_type: "text",
                label: "File sha",
                name: "sha",
                type: "string",
                optional: false,
                hint: "The SHA1 checksum ID of the blob object."
              }
            ]
          },
          {
            control_type: "select",
            label: "Release type",
            type: "string",
            name: "release_type",
            control_type: "select",
            toggle_hint: "Select from list",
            pick_list: [
              %w[Major major],
              %w[Minor minor],
              %w[Patch patch]
            ],
            toggle_field: {
              name: "release_type",
              label: "Release type",
              type: "string",
              control_type: "text",
              optional: true,
              toggle_hint: "Custom value",
            },            
            optional: true,
            hint: "Release type. Used for automatic release versioning upon pull request approval."            
          },
          {
            control_type: "text",
            label: "Release Version",
            type: "string",
            name: "release_version",
            optional: false,
            hint: "Project Release Version"            
          },
          {
            control_type: "text",
            label: "Execution Reference",
            type: "string",
            name: "execution_reference",
            optional: false,
            hint: "CICD Pipeline Execution Reference"            
          },
          {
            control_type: "text",
            label: "Execution Mode",
            type: "string",
            name: "execution_mode",
            optional: false,
            hint: "CICD Pipeline Execution Mode, eg: direct or promote"            
          },
          {
            control_type: "text",
            label: "Is Dependency",
            type: "string",
            name: "is_dependency",
            optional: false,
            hint: "Is this a dependency for any project"            
          },
          {
            control_type: "text",
            label: "External Reference ID",
            type: "string",
            name: "external_reference_id",
            optional: true,
            hint: "Any external reference ID, e.g., Jira issue # AUTO-321."            
          }, 
          {
            control_type: "text",
            label: "Comments",
            type: "string",
            name: "comments",
            optional: false,
            hint: "CICD Pipeline Execution Comments"            
          },
          {
            control_type: "text",
            label: "Release message",
            type: "string",
            name: "release_message",
            optional: true,
            hint: "Describe what changed in this release."            
          },
          {
            control_type: "text",
            label: "User id",
            type: "string",
            name: "user_id",
            optional: false,
            hint: "User id."            
          },
          {
            control_type: "text",
            label: "Commit author name",
            type: "string",
            name: "commit_author_name",
            optional: false,
            hint: "Commit author name."            
          },           
          {
            control_type: "text",
            label: "Commit author email",
            type: "string",
            name: "commit_author_email",
            optional: false,
            hint: "Commit author email address."            
          }, 
          {
            control_type: "text",
            name: "force",
            type: "boolean",
            label: "Force",
            optional: true,
            default: false
          },
        ]
      end,

      execute: lambda do |connection, input| 

        # https://docs.github.com/en/rest/reference/git#get-a-commit
        new_reference_commit = get("repos/#{connection["repo_owner"]}/#{input["repo_name"]}/git/commits/#{input["branch_reference_sha"]}")
        .after_error_response(/.*/) do |_, body, _, message|
          error("#{message}: #{body}") 
        end


        new_reference_commit.after_response do |code, body, headers|

          base_sha = body["sha"] || ""
          base_tree_sha = body["tree"]["sha"] if code == 200

          # https://docs.github.com/en/rest/reference/git#create-a-tree
          create_git_tree = post("repos/#{connection["repo_owner"]}/#{input["repo_name"]}/git/trees", {
            tree: input["git_tree"],
            base_tree: base_tree_sha
          })
          .after_error_response(/.*/) do |_, body, _, message|
            error("#{message}: #{body}") 
          end 

          create_git_tree.after_response do |code, body, headers|

            committer_obj = {
              name: "#{input["commit_author_name"]}",
              email: "#{input["commit_author_email"]}"
            }

            # Important: Store the commit message in YAML with necessary details to automate CD steps of deployments
            # Based on semantic versioning and conventional commit specifications
            commit_message = ""

            commit_message = commit_message + "execution_reference: #{input["execution_reference"]} \n" unless input["execution_reference"].nil?
            commit_message = commit_message + "is_dependency: #{input["is_dependency"]} \n" unless input["is_dependency"].nil?
            commit_message = commit_message + "execution_mode: #{input["execution_mode"]} \n" unless input["execution_mode"].nil?            
            commit_message = commit_message + "external_reference_id: #{input["external_reference_id"]} \n" unless input["external_reference_id"].nil?
            commit_message = commit_message + "user_id: #{input["user_id"]} \n" unless input["user_id"].nil?
            commit_message = commit_message + "comments: #{input["comments"]} \n" unless input["comments"].nil?

            # https://docs.github.com/en/rest/reference/git#create-a-commit
            create_commit = post("repos/#{connection["repo_owner"]}/#{input["repo_name"]}/git/commits", {
              message: commit_message,
              author: committer_obj,
              committer: committer_obj,
              tree: body["sha"],
              parents: ["#{base_sha}"]
            }).after_response do |code, body, headers|

              # https://docs.github.com/en/rest/reference/git#update-a-reference
              update_reference = patch("repos/#{connection["repo_owner"]}/#{input["repo_name"]}/git/#{input["branch_reference"]}", {
                sha: body["sha"],
                force: input["force"].present? ? input["force"] : false
              })
              .after_response do |code, body, headers|
                {
                  branch_reference: body["ref"]
                }
              end 
              .after_error_response(/.*/) do |_, body, _, message|
                error("#{message}: #{body}") 
              end # update_reference.end

            end  
            .after_error_response(/.*/) do |_, body, _, message|
              error("#{message}: #{body}") 
            end # create_commit.end 

          end # create_git_tree.end         

        end # new_reference_commit.end

      end, # execute.end

      output_fields: lambda do |connection|
        [
          {
            control_type: "text",
            label: "Branch reference",
            type: "string",
            name: "branch_reference"
          }
        ]        
      end

    },

    create_branch_ref: {
      title: "Create branch",
      subtitle: "Create branch reference in GitHub",

      help: "Please note that you are unable to create new references for empty repositories. Empty repositories are repositories without branches. Please ensure that main branch is intialized in target repo before using this action. New branch reference uses main branch as a base.",

      description: lambda do |input| 
        "Create <span class='provider'>branch</span> in " \
          "GitHub <span class='provider'>#{input["repo_name"]}</span>"
      end,

      input_fields: lambda do |object_definitions| 
        [
          {
            name: "repo_name",
            label: "Repository name",
            hint: "Target GitHub repository name to create new branch to facilitate pull request and package release.",
            optional: false
          },
          {
            name: "branch_name",
            label: "New branch name",
            hint: "Unique branch name such as feature-customer-sync or feature-jira-4530.",
            optional: false            
          }
        ]
      end,

      execute: lambda do |connection, input| 
        main_sha = ""
        # Get main branch SHA1 
        # https://docs.github.com/en/rest/reference/git#get-a-reference
        main_sha_response = get("repos/#{connection["repo_owner"]}/#{input["repo_name"]}/git/refs/heads/#{connection["base_branch_name"]}")
        .after_error_response(/.*/) do |_, body, _, message|
          error("#{message}: #{body}") 
        end

        main_sha_response.after_response do |code, body, headers|
          main_sha = body["object"]["sha"] if code == 200
          # Create reference branch
          # https://docs.github.com/en/rest/reference/git#create-a-reference
          unless main_sha.to_s.strip.blank?
            post("repos/#{connection["repo_owner"]}/#{input["repo_name"]}/git/refs", {
              ref: "refs/heads/#{input["branch_name"]}",
              sha: main_sha
            })
            .after_response do |code, body, headers| 
              {
                branch_reference: body["ref"],
                branch_reference_sha: body["object"]["sha"],
                repository_owner: connection["repo_owner"]
              }
            end
            .after_error_response(/.*/) do |_, body, _, message|
              error("#{message}: #{body}") 
            end          
          end          
        end

      end,

      output_fields: lambda do |connection|
        [
          {
            control_type: "text",
            label: "Branch reference",
            type: "string",
            name: "branch_reference"
          },          
          {
            control_type: "text",
            label: "Branch reference SHA",
            type: "string",
            name: "branch_reference_sha"
          },
          {
            control_type: "text",
            label: "Repository Owner",
            type: "string",
            name: "repository_owner"
          },
        ]        
      end
    },

    create_pull_request: {
      title: "Create pull request",
      subtitle: "Create pull request in GitHub",

      help: "Pull requests let you tell others about changes you've pushed to a branch in a repository on GitHub. Once a pull request is opened, you can discuss and review the potential changes with collaborators. Once approved, you can merge feature branch with base branch to continue CI/CD process.",

      description: lambda do |input| 
        "Create <span class='provider'>pull request</span> in " \
          "GitHub <span class='provider'>#{input["repo_name"]}</span>"
      end,

      input_fields: lambda do |object_definitions|
        [
          {
            name: "repo_name",
            label: "Repository name",
            hint: "Target GitHub repository name to create pull request.",
            optional: false
          },           
          {
            control_type: "text",
            label: "Pull request title",
            type: "string",
            name: "pull_request_title",
            optional: false,
            hint: "The title of the new pull request."
          },
          {
            control_type: "text",
            label: "Branch name",
            type: "string",
            name: "head_branch_name",
            optional: false,
            hint: "The name of the branch where your changes are implemented."
          },
          {
            control_type: "text",
            label: "Base Branch name",
            type: "string",
            name: "base_branch_name",
            optional: true,
            hint: "The name of the branch you want the changes pulled into."
          },
          {
            control_type: "text",
            label: "Reviewer Username(s)",
            type: "string",
            name: "reviewer_username",
            optional: true,
            hint: "Reviewer Username(s). Use comma separated list for multiple Reviewers."
          }          
        ]
      end,

      execute: lambda do |connection, input|
        base_branch_name = input["base_branch_name"]

        # https://docs.github.com/en/rest/reference/pulls#create-a-pull-request
        post("repos/#{connection["repo_owner"]}/#{input["repo_name"]}/pulls", {
          title: input["pull_request_title"],
          head: input["head_branch_name"],
          base: base_branch_name.present? ? base_branch_name : connection["base_branch_name"]
        })
        .after_error_response(/.*/) do |_, body, _, message|
          error("#{message}: #{body}") 
        end        
        .after_response do |code, body, headers|
          response = {
            "pull_request_number" => body["number"],
            "pull_request_id" => body["id"],
            "pull_request_url" => body["html_url"],
            "repo_owner" => connection["repo_owner"]
          }

          if "#{input["reviewer_username"]}".blank?
            response
          else
            # https://docs.github.com/en/rest/reference/pulls#request-reviewers-for-a-pull-request
            post("repos/#{connection["repo_owner"]}/#{input["repo_name"]}/pulls/#{response["pull_request_number"]}/requested_reviewers", {
              reviewers: input["reviewer_username"].split(",")
            })
            .after_error_response(/.*/) do |_, body, _, message|
              response["reviewer_assigned"] = false
              response
            end
            .after_response do |code, body, headers|
              response["reviewer_assigned"] = true
              response
            end # requested_reviewers.end

          end # if.end

        end # create_pull_request.end

      end, # execute.end

      output_fields: lambda do |connection|
        [
          {
            control_type: "text",
            label: "Pull request number",
            type: "string",
            name: "pull_request_number"
          },{
            control_type: "text",
            label: "Pull request ID",
            type: "string",
            name: "pull_request_id"
          },{
            control_type: "text",
            label: "Pull request link",
            type: "string",
            name: "pull_request_url"
          },{
            control_type: "text",
            label: "Repository Owner",
            name: "repo_owner",
            type: "string"
          },{
            control_type: "text",
            label: "Reviewer assigned",
            type: "boolean",
            name: "reviewer_assigned"
          },
        ]        
      end      
    },

    list_recent_release: {

      title: "List releases",
      subtitle: "List releases from GitHub",

      help: "Returns a list of published releases. Use the published release version for a manual deployment.",

      description: lambda do |input| 
        "List <span class='provider'>releases</span> in " \
          "GitHub <span class='provider'>#{input["repo_name"]}</span>"
      end,

      input_fields: lambda do |object_definitions|
        [
          {
            name: "repo_name",
            label: "Repository name",
            hint: "GitHub repository name.",
            optional: false
          },
          {
            name: "filter_id",
            label: "Filter ID",
            hint: "Filter releases by project or manifest ID.",
            optional: true
          },          
          {
            name: "release_per_page",
            label: "List size",
            hint: "Select how many recent releases to be listed.",
            optional: false,
            control_type: "select",
            pick_list: [
              %w[5 5],
              %w[10 10],
              %w[20 20]
            ],
            default: "10"
          }          
        ]
      end,

      execute: lambda do |connection, input|
        # https://docs.github.com/en/rest/reference/repos#list-releases
        get("repos/#{connection["repo_owner"]}/#{input["repo_name"]}/releases?page=1&per_page=#{input["release_per_page"]}")        
        .after_error_response(/.*/) do |_code, body, _, message|
          error("#{message}: #{body}") 
        end
        .after_response do |code, body, headers|
          {
            releases: body
          }
        end

      end, # execute.end

      output_fields: lambda do |object_definitions|
        [ 
          {
            name: "releases",
            type: "array",
            of: "object",
            properties: [
              { name: "id", type: "integer" },
              { name: "name" },
              { name: "tag_name" },
              { name: "package"},
              { name: "zipball_url"}
            ]
          }          
        ]

        # .after_response do |code, body, headers|

        # release_list = []
        # body.each do |release| 
        #  if call("valid_yaml", release["body"])
        #    release_details = workato.parse_yaml(release["body"])
        #    id = ""
        #   if release_details.has_key?("id")
        #    id = release_details["id"].to_s 
        # elsif release_details.has_key?("manifest") # backward compatible
        #  id = release_details["manifest"].to_s 
        #    end
        #   if input["filter_id"].blank? || input["filter_id"] == id
        #    release_list.push({
        #     release_name: release["name"].to_s,
        #    release_version: release["tag_name"].to_s,
        #   id: id,
        #  release_package: release_details["package"].to_s || "",
        #release_refs: release_details["refs"].to_s || "",
        #release_mode: release_details["release_mode"].to_s || ""
        #        })
        #     end # filter.if.end
        #  end # if.end
        # end # loop.end

        #{ release_list: release_list }

        #  end # get.end

        #  end, # execute.end


        #   output_fields: lambda do |object_definitions|
        #    [
        #      {
        #        control_type: "key_value",
        #        label: "Release list",
        #        name: "release_list",
        #        type: "array",
        #        of: "object",
        #        properties: object_definitions["release_details_output"]
        #      }           
        #    ]
      end
    },

    list_commits_on_a_pr: {
      title: "List commits on a PR",
      subtitle: "List commits on a PR",
      help: "Returns a commit from a PR.",
      description: lambda do |input| 
        "List <span class='provider'>commit</span> from GitHub <span class='provider'>#{input["repo_name"]}</span>"
      end,

      input_fields: lambda do |object_definitions|
        [
          {
            name: "repo_name",
            label: "Repository name",
            hint: "GitHub repository name.",
            optional: false
          },
          {
            name: "pr_number",
            label: "PR Number",
            hint: "GitHub PR Number",
            optional: false
          },
        ]
      end,

      execute: lambda do |connection, input|
        get("repos/#{connection['repo_owner']}/#{input['repo_name']}/pulls/#{input['pr_number']}/commits?page=1")
        .after_error_response(/.*/) do |_, body, _, message|
          error("#{message}: #{body}")
        end
        .after_response do |code, body, headers|
          if body.empty?
            error("No commits found in the pull request.")
          end

          valid_commit = body.reverse.find do |commit|
            call("valid_yaml", commit.dig("commit", "message"))
          end

          error("No Valid YAML Content Found") if valid_commit.nil?
          commit_details = workato.parse_yaml(valid_commit.dig("commit", "message"))
          output = {
            "execution_reference" => commit_details["execution_reference"].to_s,
            "external_reference_id" => commit_details["external_reference_id"].to_s,
            "is_dependency" => commit_details["is_dependency"].to_s.presence || "",
            "execution_mode" => commit_details["execution_mode"].to_s.presence || "",
            "user_id" => commit_details["user_id"].to_s.presence || "",
            "comments" => commit_details["comments"].to_s.presence || "",
            "commit_author_name" => valid_commit.dig("commit", "committer", "name"),
            "commit_author_email" => valid_commit.dig("commit", "committer", "email")
          }
          output
        end
      end,

      output_fields: lambda do |connection|
        [
          {
            control_type: "text",
            label: "Execution Reference",
            type: "string",
            name: "execution_reference",
            optional: false,
            hint: "CICD Pipeline Execution Reference"            
          },
          {
            control_type: "text",
            label: "Execution Mode",
            type: "string",
            name: "execution_mode",
            optional: false,
            hint: "CICD Pipeline Execution Mode, eg: direct or promote"            
          },
          {
            control_type: "text",
            label: "Is Dependency",
            type: "string",
            name: "is_dependency",
            optional: false,
            hint: "Is this a dependency for any project"            
          },
          {
            control_type: "text",
            label: "External Reference ID",
            type: "string",
            name: "external_reference_id",
            optional: true,
            hint: "Any external reference ID, e.g., Jira issue # AUTO-321."            
          },
          {
            control_type: "text",
            label: "User ID",
            type: "string",
            name: "user_id",
            optional: true,
            hint: "User Id used to submit the PR request."            
          },
          {
            control_type: "text",
            label: "Comments",
            type: "string",
            name: "comments",
            optional: true,
            hint: "Any comments on the commit."            
          },
          {
            control_type: "text",
            label: "Commit Author Name",
            type: "string",
            name: "commit_author_name",
            optional: true,
            hint: "Commit Author Name"            
          },
          {
            control_type: "text",
            label: "Commit Author Email",
            type: "string",
            name: "commit_author_email",
            optional: true,
            hint: "Commit Author Email"            
          },
        ]        
      end  

    }
  },

  methods: {
    valid_yaml: lambda { |log|
      is_valid = true
      if !log.nil? && !log.blank?
        log_list = log.split("\n")
        log_list.each do |line|
          is_valid = false if !line.include?(": ")
        end #loop.end
      else
        is_valid = false
      end # if.end
      is_valid
    },

    format_schema: lambda { |input|
      input&.map do |field|
        if (props = field[:properties])
          field[:properties] = call('format_schema', props)
        elsif (props = field['properties'])
          field['properties'] = call('format_schema', props)
        end
        if (name = field[:name])
          field[:label] = field[:label].presence || name.labelize
          field[:name] = name
          .gsub(/\W/) { |spl_chr| "__#{spl_chr.encode_hex}__" }
        elsif (name = field['name'])
          field['label'] = field['label'].presence || name.labelize
          field['name'] = name
          .gsub(/\W/) { |spl_chr| "__#{spl_chr.encode_hex}__" }
        end

        field
      end
    },

    format_response: lambda { |response|
      response = response&.compact unless response.is_a?(String) || response
      if response.is_a?(Array)
        response.map do |array_value|
          call('format_response', array_value)
        end
      elsif response.is_a?(Hash)
        response.each_with_object({}) do |(key, value), hash|
          key = key.gsub(/\W/) { |spl_chr| "__#{spl_chr.encode_hex}__" }
          value = call('format_response', value) if value.is_a?(Array) || value.is_a?(Hash)
          hash[key] = value
        end
      else
        response
      end
    },

    create_new_release: lambda { |connection, input|

      release_version = input["release_version"]
      release_log = input["release_log"]

      # https://docs.github.com/en/rest/reference/repos#create-a-release
      post("repos/#{connection["repo_owner"]}/#{input["repo_name"]}/releases", {
        tag_name: release_version,
        name: input["release_name"],
        generate_release_notes: input["generate_release_notes"],
        body: input["generate_release_notes"].is_not_true? ? release_log : ""
      })
      .after_error_response(/.*/) do |_, body, _, message|
        error("#{message}: #{body}") 
      end            
      .after_response do |code, body, headers|
        {
          release_version: release_version,
          release_url: body["html_url"],
          release_log: body["body"]
        }
      end # create_a_release.end 

    },

    make_schema_builder_fields_sticky: lambda { |schema|
      schema.map do |field|
        if field['properties'].present?
          field['properties'] = call('make_schema_builder_fields_sticky',
            field['properties'])
        end
        field['sticky'] = true

        field
      end
    }
  }
}