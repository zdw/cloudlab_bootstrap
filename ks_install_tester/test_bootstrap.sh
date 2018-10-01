#!/usr/bin/env bash
#
# Copyright 2017-present Open Networking Foundation
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
# http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

# test_bootstrap.sh
# Bootstraps VM's for testing kubernetes-installer script
# runs only on Ubuntu 16.04

set -e -u -o pipefail

function cloudlab_setup() {

  # Don't do anything if not a CloudLab node
  [ ! -d /usr/local/etc/emulab ] && return

  # The watchdog will sometimes reset groups, turn it off
  if [ -e /usr/local/etc/emulab/watchdog ]
  then
    sudo /usr/bin/perl -w /usr/local/etc/emulab/watchdog stop
    sudo mv /usr/local/etc/emulab/watchdog /usr/local/etc/emulab/watchdog-disabled
  fi

  # Mount extra space, if haven't already
  if [ ! -d /mnt/extra ]
  then
    sudo mkdir -p /mnt/extra

    # for NVME SSD on Utah Cloudlab, not supported by mkextrafs
    if df | grep -q nvme0n1p1 && [ -e /usr/testbed/bin/mkextrafs ]
    then
      # set partition type of 4th partition to Linux, ignore errors
      printf "t\\n4\\n82\\np\\nw\\nq" | sudo fdisk /dev/nvme0n1 || true

      sudo mkfs.ext4 /dev/nvme0n1p4
      echo "/dev/nvme0n1p4 /mnt/extra/ ext4 defaults 0 0" | sudo tee -a /etc/fstab
      sudo mount /mnt/extra
      mount | grep nvme0n1p4 || (echo "ERROR: NVME mkfs/mount failed, exiting!" && exit 1)

    elif [ -e /usr/testbed/bin/mkextrafs ]  # if on Clemson/Wisconsin Cloudlab
    then
      # Sometimes this command fails on the first try
      sudo /usr/testbed/bin/mkextrafs -s 1 -r /dev/sdb -qf "/mnt/extra/" || sudo /usr/testbed/bin/mkextrafs -s 1 -r /dev/sdb -qf "/mnt/extra/"

      # Check that the mount succeeded (sometimes mkextrafs succeeds but device not mounted)
      mount | grep sdb || (echo "ERROR: mkextrafs failed, exiting!" && exit 1)
    fi
  fi

  # precreate this for the images symlink
  sudo mkdir -p /var/lib/libvirt
  sudo rm -rf /var/lib/libvirt/images

  for DIR in docker kubelet openstack-helm nova libvirt/images
  do
      sudo mkdir -p "/mnt/extra/$DIR"
      sudo chmod -R a+rwx "/mnt/extra/$DIR"
      if [ ! -e "/var/lib/$DIR" ]
      then
          sudo ln -s "/mnt/extra/$DIR" "/var/lib/$DIR"
      fi
  done
}

echo "Installing prereqs..."
sudo apt-get update
sudo apt-get -y install apt-transport-https build-essential curl git python-dev \
                        python-pip software-properties-common sshpass libffi-dev \
                        qemu-kvm libvirt-bin libvirt-dev nfs-kernel-server socat


echo "Install ansible and python modules"
# python-openssl breaks things if installed, remove it
sudo apt-get --auto-remove --yes remove python-openssl
pip install gitpython graphviz docker "Jinja2>=2.9" virtualenv ansible \
            ansible-modules-hashivault netaddr PyOpenSSL flake8 yamllint


# create mounts/directories before installing docker
cloudlab_setup

if [ ! -x "/usr/bin/docker" ]
then
  # set up docker
  echo "Installing docker..."
  sudo apt-key adv --keyserver keyserver.ubuntu.com --recv 0EBFCD88
  sudo add-apt-repository \
        "deb [arch=amd64] https://download.docker.com/linux/ubuntu \
         $(lsb_release -cs) \
         stable"

  sudo apt-get update
  sudo apt-get install -y "docker-ce=17.03*"
fi

if [ ! -e "${HOME}/.gitconfig" ]
then
  echo "No ${HOME}/.gitconfig, setting testing defaults..."
  git config --global user.name 'Test User'
  git config --global user.email 'test@null.com'
  git config --global color.ui false
fi

if [ ! -x "/usr/local/bin/repo" ]
then
  echo "Installing repo..."

  REPO_SHA256SUM="394d93ac7261d59db58afa49bb5f88386fea8518792491ee3db8baab49c3ecda"
  curl -o /tmp/repo 'https://gerrit.opencord.org/gitweb?p=repo.git;a=blob_plain;f=repo;hb=refs/heads/stable'
  echo "$REPO_SHA256SUM  /tmp/repo" | sha256sum -c -
  sudo cp /tmp/repo /usr/local/bin/repo
  sudo chmod a+x /usr/local/bin/repo
fi

if [ ! -d "${HOME}/cord" ]
then
  # make sure we can find gerrit.opencord.org as DNS failures will fail the build
  dig +short gerrit.opencord.org || (echo "ERROR: gerrit.opencord.org can't be looked up in DNS" && exit 1)

  echo "Downloading cord with repo..."
  pushd "${HOME}"
  mkdir -p cord
  cd cord
  repo init -u https://gerrit.opencord.org/manifest -b master
  repo sync
  popd
fi

if [ ! -x "/usr/bin/kubeadm" ]
then

  cat << EOF | base64 -d > /tmp/k8s-apt-key.gpg
mQENBFUd6rIBCAD6mhKRHDn3UrCeLDp7U5IE7AhhrOCPpqGF7mfTemZYHf/5JdjxcOxoSFlK
7zwmFr3lVqJ+tJ9L1wd1K6P7RrtaNwCiZyeNPf/Y86AJ5NJwBe0VD0xHTXzPNTqRSByVYtdN
94NoltXUYFAAPZYQls0x0nUD1hLMlOlC2HdTPrD1PMCnYq/NuL/Vk8sWrcUt4DIS+0RDQ8tK
Ke5PSV0+PnmaJvdF5CKawhh0qGTklS2MXTyKFoqjXgYDfY2EodI9ogT/LGr9Lm/+u4OFPvmN
9VN6UG+s0DgJjWvpbmuHL/ZIRwMEn/tpuneaLTO7h1dCrXC849PiJ8wSkGzBnuJQUbXnABEB
AAG0QEdvb2dsZSBDbG91ZCBQYWNrYWdlcyBBdXRvbWF0aWMgU2lnbmluZyBLZXkgPGdjLXRl
YW1AZ29vZ2xlLmNvbT6JAT4EEwECACgFAlUd6rICGy8FCQWjmoAGCwkIBwMCBhUIAgkKCwQW
AgMBAh4BAheAAAoJEDdGwginMXsPcLcIAKi2yNhJMbu4zWQ2tM/rJFovazcY28MF2rDWGOnc
9giHXOH0/BoMBcd8rw0lgjmOosBdM2JT0HWZIxC/Gdt7NSRA0WOlJe04u82/o3OHWDgTdm9M
S42noSP0mvNzNALBbQnlZHU0kvt3sV1YsnrxljoIuvxKWLLwren/GVshFLPwONjw3f9Fan6G
WxJyn/dkX3OSUGaduzcygw51vksBQiUZLCD2Tlxyr9NvkZYTqiaWW78L6regvATsLc9L/dQU
iSMQZIK6NglmHE+cuSaoK0H4ruNKeTiQUw/EGFaLecay6Qy/s3Hk7K0QLd+gl0hZ1w1VzIeX
Lo2BRlqnjOYFX4CwAgADmQENBFrBaNsBCADrF18KCbsZlo4NjAvVecTBCnp6WcBQJ5oSh7+E
98jX9YznUCrNrgmeCcCMUvTDRDxfTaDJybaHugfba43nqhkbNpJ47YXsIa+YL6eEE9emSmQt
jrSWIiY+2YJYwsDgsgckF3duqkb02OdBQlh6IbHPoXB6H//b1PgZYsomB+841XW1LSJPYlYb
IrWfwDfQvtkFQI90r6NknVTQlpqQh5GLNWNYqRNrGQPmsB+NrUYrkl1nUt1LRGu+rCe4bSaS
mNbwKMQKkROE4kTiB72DPk7zH4Lm0uo0YFFWG4qsMIuqEihJ/9KNX8GYBr+tWgyLooLlsdK3
l+4dVqd8cjkJM1ExABEBAAG0QEdvb2dsZSBDbG91ZCBQYWNrYWdlcyBBdXRvbWF0aWMgU2ln
bmluZyBLZXkgPGdjLXRlYW1AZ29vZ2xlLmNvbT6JAT4EEwECACgFAlrBaNsCGy8FCQWjmoAG
CwkIBwMCBhUIAgkKCwQWAgMBAh4BAheAAAoJEGoDCyG6B/T78e8H/1WH2LN/nVNhm5TS1VYJ
G8B+IW8zS4BqyozxC9iJAJqZIVHXl8g8a/Hus8RfXR7cnYHcg8sjSaJfQhqO9RbKnffiuQgG
rqwQxuC2jBa6M/QKzejTeP0Mgi67pyrLJNWrFI71RhritQZmzTZ2PoWxfv6b+Tv5v0rPaG+u
t1J47pn+kYgtUaKdsJz1umi6HzK6AacDf0C0CksJdKG7MOWsZcB4xeOxJYuy6NuO6KcdEz8/
XyEUjIuIOlhYTd0hH8E/SEBbXXft7/VBQC5wNq40izPi+6WFK/e1O42DIpzQ749ogYQ1eode
xPNhLzekKR3XhGrNXJ95r5KO10VrsLFNd8KwAgAD
EOF

  sudo apt-key add /tmp/k8s-apt-key.gpg

  echo "deb http://apt.kubernetes.io/ kubernetes-xenial main" | sudo tee /etc/apt/sources.list.d/kubernetes.list

  sudo apt-get update

  sudo apt-get -y install \
    "kubeadm=1.11.3-*" \
    "kubelet=1.11.3-*" \
    "kubectl=1.11.3-*"

fi

if [ ! -x "/usr/local/bin/helm" ]
then
  echo "Installing helm..."

  # install helm
  HELM_VERSION="2.11.0"
  HELM_SHA256SUM="02a4751586d6a80f6848b58e7f6bd6c973ffffadc52b4c06652db7def02773a1"
  HELM_PLATFORM="linux-amd64"
  curl -L -o /tmp/helm.tgz "https://storage.googleapis.com/kubernetes-helm/helm-v${HELM_VERSION}-${HELM_PLATFORM}.tar.gz"
  echo "$HELM_SHA256SUM  /tmp/helm.tgz" | sha256sum -c -
  pushd /tmp
  tar -xzvf helm.tgz
  sudo cp ${HELM_PLATFORM}/helm /usr/local/bin/helm
  sudo chmod a+x /usr/local/bin/helm
  rm -rf helm.tgz ${HELM_PLATFORM}
  popd

  helm init --client-only
  helm repo add incubator https://kubernetes-charts-incubator.storage.googleapis.com/
fi

if [ ! -x "/usr/local/bin/minikube" ]
then
  echo "Installing minikube..."

  MINIKUBE_VERSION="0.29.0"
  MINIKUBE_DEB_VERSION="$(echo ${MINIKUBE_VERSION} | sed -n 's/\(.*\)\.\(.*\)/\1-\2/p')"
  MINIKUBE_SHA256SUM="7513e963fdb12b86bf80ae0eb17e9eeb8c03d23bb9d6b99c8cbcd611a7fb8c1e"
  curl -L -o /tmp/minikube.deb "https://storage.googleapis.com/minikube/releases/v${MINIKUBE_VERSION}/minikube_${MINIKUBE_DEB_VERSION}.deb"
  echo "$MINIKUBE_SHA256SUM  /tmp/minikube.deb" | sha256sum -c -
  pushd /tmp
  sudo dpkg -i minikube.deb
  rm -f minikube.deb
fi

if [ ! -x "/usr/bin/vagrant" ]
then
  echo "Installing vagrant and associated tools..."

  VAGRANT_VERSION="2.1.5"
  VAGRANT_SHA256SUM="458b1804b61443cc39ce1fe9ef9aca53c403f25c36f98d0f15e1b284f2bddb65"  # version 2.1.5
  curl -o /tmp/vagrant.deb https://releases.hashicorp.com/vagrant/${VAGRANT_VERSION}/vagrant_${VAGRANT_VERSION}_x86_64.deb
  echo "$VAGRANT_SHA256SUM  /tmp/vagrant.deb" | sha256sum -c -
  sudo dpkg -i /tmp/vagrant.deb
fi

echo "Installing vagrant plugins if needed..."
VAGRANT_LIBVIRT_VERSION="0.0.43"
vagrant plugin list | grep -q vagrant-libvirt || vagrant plugin install vagrant-libvirt --plugin-version ${VAGRANT_LIBVIRT_VERSION}
vagrant plugin list | grep -q vagrant-mutate || vagrant plugin install vagrant-mutate

echo "Obtaining libvirt image of Ubuntu"
UBUNTU_VERSION=${UBUNTU_VERSION:-bento/ubuntu-16.04}
vagrant box list | grep "${UBUNTU_VERSION}" | grep virtualbox || vagrant box add --provider virtualbox "${UBUNTU_VERSION}"
vagrant box list | grep "${UBUNTU_VERSION}" | grep libvirt || vagrant mutate "${UBUNTU_VERSION}" libvirt --input-provider virtualbox


echo "DONE!"

