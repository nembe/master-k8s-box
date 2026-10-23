Vagrant.configure("2") do |config|
  config.vm.box_check_update = false

  config.vm.define "master" do |master|
    master.vm.box = "bento/rockylinux-8"
    master.vm.hostname = "master-node"
    master.vm.boot_timeout = 600

  # VMware shared folders (vmhgfs-fuse) do not support dmode/fmode.
  # Use owner/group settings for predictable permissions instead.
  master.vm.synced_folder ".", "/vagrant", disabled: false, owner: "vagrant", group: "vagrant"

    master.vm.network :private_network, ip: "192.168.79.131"
    master.vm.network "forwarded_port", guest: 22, host: 2206, id: "ssh"

    # Run provisioning as root (required for kubeadm/containerd/system changes)
    master.vm.provision "shell", path: "kubernetes_master.sh", privileged: true

    # Ensure we use the box's builtin vagrant account and key instead of
    # having Vagrant try to insert a new key (common cause of auth failures)
    master.ssh.username = "vagrant"
    master.ssh.insert_key = false
    master.ssh.private_key_path = "~/.vagrant.d/insecure_private_key"
    master.ssh.keep_alive = true
    master.ssh.connect_timeout = 120
  end
   
  config.vm.provider "vmware_desktop" do |vb|
    vb.gui = false
    vb.memory = "4096"
    vb.cpus = 2
 end
end
