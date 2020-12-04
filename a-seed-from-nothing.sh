#!/bin/bash

# Reset SECONDS
SECONDS=0

# Registry IP
registry_ip=$1
echo "[INFO] Given docker registry IP: $registry_ip"

# Disable the firewall.
rpm -q firewalld && sudo systemctl is-enabled firewalld && sudo systemctl stop firewalld && sudo systemctl disable firewalld

# Disable SELinux.
sudo setenforce 0

# Exit on error
# NOTE(priteau): Need to be set here as setenforce can return a non-zero exit
# code
set -e

# Work around connectivity issues seen while configuring this node as seed
# hypervisor with Kayobe
sudo dnf install -y network-scripts
sudo rm -f /etc/sysconfig/network-scripts/ifcfg-ens3
cat <<EOF | sudo tee /etc/sysctl.d/70-ipv6.conf
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
EOF
sudo sysctl --load /etc/sysctl.d/70-ipv6.conf
sudo systemctl is-active NetworkManager && (sudo systemctl disable NetworkManager; sudo systemctl enable network; sudo systemctl stop NetworkManager; sudo systemctl start network)

# Clone Kayobe.
cd $HOME
[[ -d kayobe ]] || git clone https://opendev.org/openstack/kayobe.git -b stable/ussuri
cd kayobe

# Bump the provisioning time - it can be lengthy on virtualised storage
sed -i.bak 's%^[# ]*wait_active_timeout:.*%    wait_active_timeout: 5000%' ~/kayobe/ansible/overcloud-provision.yml

# Clone the Tenks repository.
[[ -d tenks ]] || git clone https://opendev.org/openstack/tenks.git

# Clone this Kayobe configuration.
mkdir -p config/src
cd config/src/
# FIXME: stable/ussuri branch currently specifies a CentOS 8.1 based seed VM image,
# which doesn't work with a Bifrost image based on CentOS 8.2 (libvirt incompatibilities exposed by virt-customize)
#[[ -d kayobe-config ]] || git clone https://github.com/stackhpc/a-universe-from-nothing.git -b stable/ussuri kayobe-config
[[ -d kayobe-config ]] || git clone https://github.com/stackhpc/a-universe-from-nothing.git -b seed-centos-8.2 kayobe-config

# Set default registry name to the one we just created
sed -i.bak 's/^docker_registry.*/docker_registry: '$registry_ip':4000/' kayobe-config/etc/kayobe/docker.yml

# Configure host networking (bridge, routes & firewall)
./kayobe-config/configure-local-networking.sh

# Install kayobe.
cd ~/kayobe
./dev/install-dev.sh

# Prepare LVM on scratch disk: ensure the scratch disk is not mounted 
scratch_dev="/dev/vdb"
while read blkdev fs rest
do
    [[ $blkdev = "$scratch_dev" ]] && (echo Unmounting scratch device $scratch_dev ; sudo umount $scratch_dev)
done < /proc/mounts

# Configure Kayobe to make use of the scratch disk for LVM for libvirt
# This will mount the LVM volume on /var/lib/libvirt/images
sed -i.bak -e "s%^[# ]*seed_hypervisor_lvm_groups:.*%seed_hypervisor_lvm_groups: \"{{ seed_hypervisor_lvm_groups_with_data }}\"%" \
           -e "s%^[# ]*seed_hypervisor_lvm_group_data_disks:.*%seed_hypervisor_lvm_group_data_disks: \[\"$scratch_dev\"\]%" \
           ~/kayobe/config/src/kayobe-config/etc/kayobe/seed-hypervisor.yml

# Remap Tenks configuration to share the storage at /var/lib/libvirt/images
sed -i.bak -e "s%^[# ]*libvirt_pool_path:.*%libvirt_pool_path: /var/lib/libvirt/images/%" \
           -e 's%^libvirt_pool_name:.*%libvirt_pool_name: default%' \
           ~/kayobe/tenks/ansible/group_vars/libvirt

# Deploy hypervisor services.
./dev/seed-hypervisor-deploy.sh

# Deploy a seed VM.
# NOTE: This will work the first time because the packet configuration uses a
# custom docker registry.
if ! ./dev/seed-deploy.sh; then
    # Pull, retag images, then push to our local registry.
    ./config/src/kayobe-config/pull-retag-push-images.sh ussuri

    # Deploy a seed VM. Should work this time.
    ./dev/seed-deploy.sh
fi

# Duration
duration=$SECONDS
echo "[INFO] $(($duration / 60)) minutes and $(($duration % 60)) seconds elapsed."
