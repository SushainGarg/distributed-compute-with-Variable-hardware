sudo apt update && sudo apt install -y nfs-kernel-server
sudo mkdir -p /mnt/cluster-storage
sudo chown -R nobody:nogroup /mnt/cluster-storage
# change mount drive to actual path
sudo chmod 777 /mnt/cluster-storage

# Export to subnet (e.g., 192.168.1.0/24)
echo "/mnt/cluster-storage 192.168.1.0/24(rw,sync,no_subtree_check,no_root_squash)" | sudo tee -a /etc/exports
sudo exportfs -a
sudo systemctl restart nfs-kernel-server