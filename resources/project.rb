=begin
#<
project provider configures a rundeck project

@action create  Create a rundeck project.
@action delete  Delete a rundeck project.

@section Examples

     # winrm example
     rundeck_server_project 'windows_servers' do
       executor({
         provider: 'overthere-winrm',
         config: {
          'winrm-auth-type'      => 'certificate',
          'winrm-protocol'       => 'https',
          'winrm-cert-trust'     => 'all',
          'winrm-hostname-trust' => 'all',
          'winrm-cert'           =>  [PKCS#12 key for Java]
         }
       })
       sources([{
        'type'            => 'url',
        'config.url'      => "http://url,
        'config.timeout'  => 30,
        'config.cache'    => true
       }])
       properties({
        'project.plugin.notification.PluginFoo.team' => 'bar',
       })
     end

     # ssh example
     rundeck_server_project 'linux_servers' do
       executor 'ssh'
       sources([{
        'type'            => 'url',
        'config.url'      => "http://chef-bridge/linux,
        'config.timeout'  => 30,
        'config.cache'    => true
      }])
      scm_import('config.strictHostKeyChecking' => 'no',
        'roles.0' => myrole,
        'roles.count' => 1,
        'config.url' => 'git@github.com:myaccount/rundeck-jobs.git',
        'trackedItems.count' => 0,
        'config.sshPrivateKeyPath' => 'keys/mykey')
     end
#>
=end

# <> @property name Name of the project
property :name,
          kind_of: String,
          name_property: true,
          regex: /^[-_+.a-zA-Z0-9]+$/

# <> @property executor Executor name + configuration. Could be a plain string (ssh) or complex hash configuration.
property :executor,
          kind_of: [Symbol, Hash],
          default: :ssh,
          callbacks: ({
            must_contain_provider: lambda do |executor|
              executor.is_a?(Symbol) || !executor['provider'].nil? || !executor[:provider].nil?
            end,
            must_contain_config: lambda do |executor|
              executor.is_a?(Symbol) || (executor['config'] || executor[:config]).is_a?(Hash)
            end
          })

# <> @property scm-import setting of the project
property :scm_import,
          kind_of: [FalseClass, Hash],
          required: false,
          default: false

# <> @property sources List of node sources
property :sources,
          kind_of: Array,
          required: true,
          callbacks: ({
            must_be_an_array_of_hashes: lambda do |sources|
              sources.all? { |source| source.is_a?(Hash) }
            end,
            must_contain_type: lambda do |sources|
              sources.all? { |source| source['type'] || source[:type] }
            end
          })

# <> @property properties Hash of project properties
property :properties,
          kind_of: Hash,
          required: false,
          default: {}

property :cookbook,
          kind_of: String,
          default: 'rundeck-server'

action :create do
  %w(etc var).each do |d|
    directory ::File.join(node['rundeck_server']['datadir'], 'projects', new_resource.name, d) do
      user  'rundeck'
      group 'rundeck'
      mode '0770'
      recursive true
    end
  end

  properties = {}
  properties.merge!(new_resource.properties)
  properties['project.name'] = new_resource.name

  executor = new_resource.executor
  if executor.is_a? Symbol
    # Template executor config
    case executor
    when :ssh
      executor = {
        provider: 'jsch-ssh',
        config: {
          'ssh-authentication'  => 'privateKey',
          'ssh-keypath'         => "#{node['rundeck_server']['basedir']}/.ssh/id_rsa"
        }
      }
    when :winrm
      fail 'WinRM template not yet supported'
    else
      fail "Unknown executor template: #{new_resource.executor}"
    end
  end

  properties['service.NodeExecutor.default.provider'] = executor[:provider] || executor['provider']
  (executor[:config] || executor['config']).each do |key, value|
    properties["project.#{key}"] = value
  end

  # configure scm_import
  if new_resource.scm_import
    scm_import = {}
    scm_import['scm.import.type'] = 'git-import'
    scm_import['scm.import.username'] = 'rundeck'
    scm_import['scm.import.config.branch'] = 'master'
    scm_import['scm.import.config.strictHostKeyChecking'] = 'yes'
    scm_import['scm.import.config.pathTemplate'] = '${job.group}${job.name}-${job.id}.${config.format}'
    scm_import['scm.import.config.dir'] = ::File.join(node['rundeck_server']['datadir'], 'projects', new_resource.name, 'scm')
    scm_import['scm.import.config.format'] = 'yaml'
    scm_import['scm.import.config.useFilePattern'] = true
    scm_import['scm.import.config.importUuidBehavior'] = 'preserve'
    scm_import['scm.import.config.filePattern'] = '.*\\.yaml'
    scm_import['scm.import.config.fetchAutomatically'] = true
    scm_import['scm.import.config.enabled'] = true
    new_resource.scm_import.each do |k, v|
      scm_import["scm.import.#{k}"] = v
    end

    directory ::File.join(node['rundeck_server']['datadir'], 'projects', new_resource.name, 'scm') do
      user     'rundeck'
      group    'rundeck'
      mode     '0770'
    end

    template ::File.join(node['rundeck_server']['datadir'], 'projects', new_resource.name, 'etc', 'scm-import.properties') do
      source   'properties.erb'
      user     'rundeck'
      group    'rundeck'
      mode     '0660'
      cookbook new_resource.cookbook
      variables(properties: scm_import)
    end
  end

  new_resource.sources.each_with_index do |source, i|
    source.each do |k, v|
      properties["resources.source.#{i + 1}.#{k}"] = v
    end
  end
  properties['service.FileCopier.default.provider'] = 'jsch-scp'

  template ::File.join(node['rundeck_server']['datadir'], 'projects', new_resource.name, 'etc', 'project.properties') do
    source   'properties.erb'
    user     'rundeck'
    group    'rundeck'
    mode     '0660'
    cookbook new_resource.cookbook
    variables(properties: properties)
  end
end

action :delete do
  directory ::File.join(node['rundeck_server']['datadir'], 'projects', new_resource.name) do
    recursive true
    action :delete
  end
end
