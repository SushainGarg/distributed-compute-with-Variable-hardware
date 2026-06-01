# worth checking if the container toolkit LREADY EXISTS OR THE GPG SIGNATURE, sometimes one or the other is present then no need to run al the cmds
curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey | sudo gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg
curl -s -L https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list | sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' | sudo tee /etc/apt/sources.list.d/nvidia-container-toolkit.list
sudo apt-get update && sudo apt-get install -y nvidia-container-toolkit

# these are to set the containerd application(manages containerised apps) config.
# config is usually present in /etc/containerd/config.toml on linux(ubuntu)
# This is responsible to inject configuration into the containerd config 
# for increasing visible hardware scope to include the GPUs(nvidia ones)
sudo nvidia-ctk runtime configure --runtime=containerd
sudo systemctl restart containerd