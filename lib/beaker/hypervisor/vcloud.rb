require 'yaml' unless defined?(YAML)

module Beaker 
  class Vcloud < Beaker::Hypervisor
    CHARMAP = [('a'..'z'),('0'..'9')].map{|r| r.to_a}.flatten

    def initialize(vcloud_hosts, options)
      @options = options
      @logger = options[:logger]
      @vcloud_hosts = vcloud_hosts

      raise 'You must specify a datastore for vCloud instances!' unless @options['datastore']
      raise 'You must specify a resource pool for vCloud instances!' unless @options['resourcepool']
      raise 'You must specify a folder for vCloud instances!' unless @options['folder']
      vsphere_credentials = VsphereHelper.load_config(@options[:dot_fog])

      @logger.notify "Connecting to vSphere at #{vsphere_credentials[:server]}" +
        " with credentials for #{vsphere_credentials[:user]}"

      @vsphere_helper = VsphereHelper.new( vsphere_credentials )
    end

    def wait_for_dns_resolution host, try, attempts
      @logger.notify "Waiting for #{host['vmhostname']} DNS resolution"
      begin
        Socket.getaddrinfo(host['vmhostname'], nil)
      rescue
        if try <= attempts
          sleep 5
          try += 1

          retry
        else
          raise "DNS resolution failed after #{@options[:timeout].to_i} seconds"
        end
      end
    end

    def booting_host host, try, attempts
      @logger.notify "Booting #{host['vmhostname']} (#{host.name}) and waiting for it to register with vSphere"
      until
        @vsphere_helper.find_vms(host['vmhostname'])[host['vmhostname']].summary.guest.toolsRunningStatus == 'guestToolsRunning' and
        @vsphere_helper.find_vms(host['vmhostname'])[host['vmhostname']].summary.guest.ipAddress != nil
        if try <= attempts
          sleep 5
          try += 1
        else
          raise "vSphere registration failed after #{@options[:timeout].to_i} seconds"
        end
      end
    end

    def generate_host_name
      CHARMAP[rand(25)] + (0...14).map{CHARMAP[rand(CHARMAP.length)]}.join
    end

    def create_clone_spec host
      # Add VM annotation
      configSpec = RbVmomi::VIM.VirtualMachineConfigSpec(
        :annotation =>
          'Base template:  ' + host['template'] + "\n" +
          'Creation time:  ' + Time.now.strftime("%Y-%m-%d %H:%M") + "\n\n" +
          'CI build link:  ' + ( ENV['BUILD_URL'] || 'Deployed independently of CI' )
      )

      # Are we using a customization spec?
      customizationSpec = @vsphere_helper.find_customization( host['template'] )

      if customizationSpec
        # Print a logger message if using a customization spec
        @logger.notify "Found customization spec for '#{host['template']}', will apply after boot"
      end

      # Put the VM in the specified folder and resource pool
      relocateSpec = RbVmomi::VIM.VirtualMachineRelocateSpec(
        :datastore    => @vsphere_helper.find_datastore(@options['datastore']),
        :pool         => @vsphere_helper.find_pool(@options['resourcepool']),
        :diskMoveType => :moveChildMostDiskBacking
      )

      # Create a clone spec
      spec = RbVmomi::VIM.VirtualMachineCloneSpec(
        :config        => configSpec,
        :location      => relocateSpec,
        :customization => customizationSpec,
        :powerOn       => true,
        :template      => false
      )
      spec
    end

    def provision
      vsphere_vms = {}

      try = 1
      attempts = @options[:timeout].to_i / 5

      start = Time.now
      @vcloud_hosts.each_with_index do |h, i|
        # Generate a randomized hostname
        h['vmhostname'] = generate_host_name

        if h['template'] =~ /\//
          templatefolders = h['template'].split('/')
          h['template'] = templatefolders.pop
        end

        @logger.notify "Deploying #{h['vmhostname']} (#{h.name}) to #{@options['folder']} from template '#{h['template']}'"

        vm = {}

        if templatefolders
          vm[h['template']] = @vsphere_helper.find_folder(templatefolders.join('/')).find(h['template'])
        else
          vm = @vsphere_helper.find_vms(h['template'])
        end

        if vm.length == 0
          raise "Unable to find template '#{h['template']}'!"
        end

        spec = create_clone_spec(h)

        # Deploy from specified template
        if (@vcloud_hosts.length == 1) or (i == @vcloud_hosts.length - 1)
          vm[h['template']].CloneVM_Task( :folder => @vsphere_helper.find_folder(@options['folder']), :name => h['vmhostname'], :spec => spec ).wait_for_completion
        else
          vm[h['template']].CloneVM_Task( :folder => @vsphere_helper.find_folder(@options['folder']), :name => h['vmhostname'], :spec => spec )
        end
      end
      @logger.notify 'Spent %.2f seconds deploying VMs' % (Time.now - start)

      try = (Time.now - start) / 5
      duration = run_and_report_duration do 
        @vcloud_hosts.each_with_index do |h, i|
          booting_host(h, try, attempts)
        end
      end
      @logger.notify "Spent %.2f seconds booting and waiting for vSphere registration" % duration

      try = (Time.now - start) / 5
      duration = run_and_report_duration do
        @vcloud_hosts.each_with_index do |h, i|
          wait_for_dns_resolution(h, try, attempts)
        end
      end
      @logger.notify "Spent %.2f seconds waiting for DNS resolution" % duration

      @vsphere_helper.close 
    end

    def cleanup
      @logger.notify "Destroying vCloud boxes"

      vm_names = @vcloud_hosts.map {|h| h['vmhostname'] }.compact
      if @vcloud_hosts.length != vm_names.length
        @logger.warn "Some hosts did not have vmhostname set correctly! This likely means VM provisioning was not successful"
      end
      vms = @vsphere_helper.find_vms vm_names
      vm_names.each do |name|
        unless vm = vms[name]
          raise "Couldn't find VM #{name} in vSphere!"
        end

        if vm.runtime.powerState == 'poweredOn'
          @logger.notify "Shutting down #{vm.name}"
          duration = run_and_report_duration do
            vm.PowerOffVM_Task.wait_for_completion
          end
          @logger.notify "Spent %.2f seconds halting #{vm.name}" % duration
        end

        duration = run_and_report_duration do 
          vm.Destroy_Task
        end
        @logger.notify "Spent %.2f seconds destroying #{vm.name}" % duration
      end
      @vsphere_helper.close
    end

  end
end
