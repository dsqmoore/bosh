module EsxCloud

  class Cloud

    BOSH_AGENT_PROPERTIES_ID = "Bosh_Agent_Properties"

    attr_accessor :client

    def initialize(options)
      @logger = Bosh::Director::Config.logger
      @req_id = 0
      @server = "middle"
      @agent_properties = options["agent"]
      @nats = options["nats"]
      @esxmgr = options["esxmgr"]
      @vm_mac = "00:00:00:00:00:00"

      @logger.info("ESXCLOUD: options #{@nats}")
      @logger.info("ESXCLOUD: options #{@esxmgr}")
    end

    def generate_unique_name
      UUIDTools::UUID.random_create.to_s
    end

    def generate_agent_env(name, vm, agent_id, networking_env, disk_env)
      vm_env = {
          "name" => name,
          "id" => vm
      }
      env = {}
      env["vm"] = vm_env
      env["agent_id"] = agent_id
      env["networks"] = networking_env
      env["disks"] = disk_env
      env.merge!(@agent_properties)
      env
    end

    def build_agent_network_env(devices, networks)
      network_env = {}
      networks.each do |network_name, network|
        network_entry = network.dup
        devices.each do |d|
          if d["vswitch"] == network["cloud_properties"]["name"]
            network_entry["mac"] = d["mac"]
            break
          end
        end
        network_env[network_name] = network_entry
      end
      network_env
    end

    def send_request(payload)
      rtn = false
      rtn_payload = nil

      uri = "nats://#{@nats["user"]}:#{@nats["password"]}@#{@nats["host"]}:#{@nats["port"]}"
      @logger.info("ESXCLOUD: connecting to #{uri}")

      NATS.start(:uri => uri) {
        b = EsxMQ::Backend.new(@server, 'dummy_unused', EsxMQ::MQ::DEFAULT_FILE_UPLOAD_PORT)
        @req_id = @req_id + 1
        b.subscribe { |r_id, msg|
          raise "bad message #{msg}, r_id #{r_id} , req_id #{@req_id}" if r_id != @req_id.to_s
          if (msg.returnStatus == EsxMQ::ESXReturnStatus::SUCCESS)
            rtn_payload = EsxMQ::MsgPayload.getPayloadMsg(msg.payload)
            rtn = true
          end
          NATS.stop
        }
        req = EsxMQ::RequestMsg.new(@req_id)
        req.payload = payload
        b.publish(req)
      }
      return rtn, rtn_payload
    end


    def send_file(name, full_file_name)
      sock = TCPSocket.open(@esxmgr["host"], EsxMQ::MQ::DEFAULT_FILE_UPLOAD_PORT)
      src_file = open(full_file_name, "rb")

      name = name.ljust(256)
      sock.write(name)

      while (file_content = src_file.read(4096))
        sock.write(file_content)
      end
      sock.flush
      sock.close

      # XXX, Wait for server to receive the last bits, The flush above does not
      #      seem to be working well.
      sleep(5)
    end


    def create_stemcell(image, _)
      with_thread_name("create_stemcell(#{image}, _)") do
        result = nil
        Dir.mktmpdir do |temp_dir|
          @logger.info("Extracting stemcell to: #{temp_dir}, image is #{image}")


          name = "sc-#{generate_unique_name}"
          @logger.info("Generated name: #{name}")

          # upload stemcell to esx controller
          send_file(name, image)

          # send "create stemcell" command to controller
          create_sc = EsxMQ::CreateStemcellMsg.new(name, name)
          rtn, rtn_payload = send_request(create_sc)
          result = name if rtn
        end
        result
      end
    end

    def delete_stemcell(stemcell)
      with_thread_name("delete_stemcell(#{stemcell})") do
        # send delete stemcell command to esx controller
        delete_sc = EsxMQ::DeleteStemcellMsg.new(stemcell)
        send_request(delete_sc)
      end
    end

    def create_vm(agent_id, stemcell, resource_pool, networks, disk_locality = nil)
      with_thread_name("create_vm(#{agent_id}, ...)") do
        result = nil

        # TODO do we need to worry about disk locality
        name = "vm-#{generate_unique_name}"
        @logger.info("Creating vm: #{name}")

        create_vm = EsxMQ::CreateVmMsg.new(name)
        create_vm.cpu = resource_pool["cpu"]
        create_vm.ram = resource_pool["ram"]
        devices = []
        networks.each_value do |network|
          net = Hash.new
          net["vswitch"] = network["cloud_properties"]["name"]
          net["mac"] =  @vm_mac
          devices << net
        end

        create_vm.stemcell = stemcell
        # TODO fix these
        system_disk = 0
        ephemeral_disk = 1

        network_env = build_agent_network_env(devices, networks)
        # TODO fix disk_env
        disk_env = { "system" => system_disk,
                     "ephemeral" => ephemeral_disk,
                     "persistent" => {}
        }
        create_vm.guestInfo = generate_agent_env(name, name, agent_id, network_env, disk_env)

        rtn, dummy = send_request(create_vm)
        result = name if rtn
        result
      end
    end

    def delete_vm(vm_cid)
      with_thread_name("delete_vm(#{vm_cid})") do
        @logger.info("Deleting vm: #{vm_cid}")

        delete_vm = EsxMQ::DeleteVmMsg.new(vm_cid)
        send_request(delete_vm)
      end
    end

    def configure_networks(vm_cid, networks)
      with_thread_name("configure_networks(#{vm_cid}, ...)") do
        @logger.info("Configuring: #{vm_cid} to use the following network settings: #{networks.pretty_inspect}")
        raise "ESXCLOUD: configure networks is not implemented yet"
      end
    end

    def attach_disk(vm_cid, disk_cid)
      with_thread_name("attach_disk(#{vm_cid}, #{disk_cid})") do
        @logger.info("Attaching disk: #{disk_cid} on vm: #{vm_cid}")
        raise "ESXCLOUD: attach disk is not implemented yet"
      end
    end

    def detach_disk(vm_cid, disk_cid)
      with_thread_name("detach_disk(#{vm_cid}, #{disk_cid})") do
        @logger.info("Detaching disk: #{disk_cid} from vm: #{vm_cid}")
        raise "ESXCLOUD: Detaching disk is not implemented yet"
      end
    end

    def create_disk(size, _ = nil)
      with_thread_name("create_disk(#{size}, _)") do
        @logger.info("Creating disk with size: #{size}")
        raise "ESXCLOUD: Create disk not implemented yet"
      end
    end

    def delete_disk(disk_cid)
      with_thread_name("delete_disk(#{disk_cid})") do
        @logger.info("Deleting disk: #{disk_cid}")
        raise "ESXCLOUD: Delete disk not implemented yet"
      end
    end

    def validate_deployment(old_manifest, new_manifest)
      # TODO: still needed? what does it verify? cloud properties? should be replaced by normalize cloud properties?
      @logger.info("Validate deployment")
      raise "ESXCLOUD: Validate deployment not implemented yet"
    end
  end
end
