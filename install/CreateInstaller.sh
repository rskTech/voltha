#!/bin/bash


iVmName="vInstaller"
baseImage="Ubuntu1604LTS"
iVmNetwork="vagrant-libvirt"
installerArchive="installer.tar.bz2"
installerDirectory="volthaInstaller"
installerPart="installer.part"
shutdownTimeout=5
ipTimeout=10

lBlue='\033[1;34m'
green='\033[0;32m'
orange='\033[0;33m'
NC='\033[0m'
red='\033[0;31m'
yellow='\033[1;33m'
dGrey='\033[1;30m'
lGrey='\033[1;37m'
lCyan='\033[1;36m'

uId=`id -u`
wd=`pwd`

# Validate that vagrant is installed.
echo -e "${lBlue}Ensure that ${lCyan}vagrant${lBlue} is installed${NC}"
vInst=`which vagrant`

if [ -z "$vInst" ]; then
	wget https://releases.hashicorp.com/vagrant/1.9.5/vagrant_1.9.5_x86_64.deb
	sudo dpkg -i vagrant_1.8.5_x86_64.deb
	rm vagrant_1.8.5_x86_64.deb
fi
unset vInst

# Validate that ansible is installed
echo -e "${lBlue}Ensure that ${lCyan}ansible${lBlue} is installed${NC}"
aInst=`which ansible`

if [ -z "$aInst" ]; then
	sudo apt-get install -y software-properties-common
	sudo apt-add-repository ppa:ansible/ansible
	sudo apt-get update
	sudo apt-get install -y ansible
fi
unset vInst

# Verify if this is intended to be a test environment, if so start 3 VMs
# to emulate the production installation cluster.
if [ $# -eq 1 -a "$1" == "test" ]; then
	echo -e "${lBlue}Testing, create the ${lCyan}ha-serv${lBlue} VMs${NC}"
	# Update the vagrant settings file
	sed -i -e '/server_name/s/.*/server_name: "ha-serv'${uId}'-"/' settings.vagrant.yaml
	sed -i -e '/docker_push_registry/s/.*/docker_push_registry: "vinstall'${uId}':5000"/' ansible/group_vars/all
	sed -i -e "/vinstall/s/vinstall/vinstall${uId}/" ../ansible/roles/docker/templates/daemon.json

	# Set the insecure registry configuration based on the installer hostname
	echo -e "${lBlue}Set up the inescure registry hostname ${lCyan}vinstall${uId}${NC}"
	echo '{' > ansible/roles/voltha/templates/daemon.json
	echo '"insecure-registries" : ["vinstall'${uId}':5000"]' >> ansible/roles/voltha/templates/daemon.json
	echo '}' >> ansible/roles/voltha/templates/daemon.json

	vagrant destroy ha-serv${uId}-{1,2,3}
	vagrant up ha-serv${uId}-{1,2,3}
	./devSetHostList.sh
	# Change the installer name
	iVmName="vInstaller${uId}"
else
	rm -fr .test
	# Clean out the install config file keeping only the commented lines
        # which serve as documentation.
	sed -i -e '/^#/!d' install.cfg
	# Set the insecure registry configuration based on the installer hostname
	echo -e "${lBlue}Set up the inescure registry hostname ${lCyan}vinstall${uId}${NC}"
	echo '{' > ansible/roles/voltha/templates/daemon.json
	echo '"insecure-registries" : ["vinstall:5000"]' >> ansible/roles/voltha/templates/daemon.json
	echo '}' >> ansible/roles/voltha/templates/daemon.json
fi


# Shut down the domain in case it's running.
echo -e "${lBlue}Shut down the ${lCyan}$iVmName${lBlue} VM if running${NC}"
ctr=0
vStat=`virsh list | grep $iVmName`
virsh shutdown $iVmName
while [ ! -z "$vStat" ];
do
	echo "Waiting for $iVmName to shut down"
	sleep 2
	vStat=`virsh list | grep $iVmName`
	ctr=`expr $ctr + 1`
	if [ $ctr -eq $shutdownTimeout ]; then
		echo -e "${red}Tired of waiting, forcing the VM off${NC}"
		virsh destroy $iVmName
		vStat=`virsh list | grep $iVmName`
	fi
done


# Delete the VM and ignore any errors should they occur
echo -e "${lBlue}Undefining the ${lCyan}$iVmName${lBlue} domain${NC}"
virsh undefine $iVmName

# Remove the associated volume
echo -e "${lBlue}Removing the ${lCyan}$iVmName.qcow2${lBlue} volume${NC}"
virsh vol-delete "${iVmName}.qcow2" default

# Clone the base vanilla ubuntu install
echo -e "${lBlue}Cloning the ${lCyan}$baseImage.qcow2${lBlue} to ${lCyan}$iVmName.qcow2${NC}"
virsh vol-clone "${baseImage}.qcow2" "${iVmName}.qcow2" default

# Create the xml file and define the VM for virsh
echo -e "${lBlue}Defining the  ${lCyan}$iVmName${lBlue} virtual machine${NC}"
cat vmTemplate.xml | sed -e "s/{{ VMName }}/$iVmName/g" | sed -e "s/{{ VMNetwork }}/$iVmNetwork/g" > tmp.xml

virsh define tmp.xml

rm tmp.xml

# Start the VMm, if it's already running just ignore the error
echo -e "${lBlue}Starting the ${lCyan}$iVmName${lBlue} virtual machine${NC}"
virsh start $iVmName > /dev/null 2>&1

# Generate a keypair for communicating with the VM
echo -e "${lBlue}Generating the key-pair for communication with the VM${NC}"
ssh-keygen -f ./key -t rsa -N ''

mv key key.pem

# Clone BashLogin.sh and add the public key to it for later use.
echo -e "${lBlue}Creating the pre-configuration script${NC}"
cp BashLogin.sh bash_login.sh
echo "cat <<HERE > .ssh/authorized_keys" >> bash_login.sh
cat key.pub >> bash_login.sh
echo "HERE" >> bash_login.sh
echo "chmod 400 .ssh/authorized_keys" >> bash_login.sh
echo "rm .bash_login" >> bash_login.sh
echo "logout" >> bash_login.sh
rm key.pub



# Get the VM's IP address
ctr=0
ipAddr=""
while [ -z "$ipAddr" ];
do
	echo -e "${lBlue}Waiting for the VM's IP address${NC}"
	ipAddr=`virsh domifaddr $iVmName | tail -n +3 | awk '{ print $4 }' | sed -e 's~/.*~~'`
	sleep 3
	if [ $ctr -eq $ipTimeout ]; then
		echo -e "${red}Tired of waiting, please adjust the ipTimeout if the VM is slow to start${NC}"
		exit
	fi
	ctr=`expr $ctr + 1`
done

echo -e "${lBlue}The IP address is: ${lCyan}$ipAddr${NC}"

# Copy the pre-config file to the VM
echo -e "${lBlue}Transfering pre-configuration script to the VM${NC}"
scp -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no bash_login.sh vinstall@$ipAddr:.bash_login

rm bash_login.sh

# Run the pre-config file on the VM
echo -e "${lBlue}Running the pre-configuration script on the VM${NC}"
ssh -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no vinstall@$ipAddr 

# If we're in test mode, change the hostname of the installer vm
if [ $# -eq 1 -a "$1" == "test" ]; then
	echo -e "${lBlue}Test mode, change the installer host name to ${yellow}vinstall${uId}${NC}"
	ssh -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no -i key.pem vinstall@$ipAddr \
		sudo hostnamectl set-hostname vinstall${uId}
	ssh -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no -i key.pem vinstall@$ipAddr \
		sudo service networking restart
fi

# Ensure that the voltha VM is running so that images can be secured
echo -e "${lBlue}Ensure that the ${lCyan}voltha VM${lBlue} is running${NC}"
vVM=`virsh list | grep voltha_voltha${uId}`

if [ -z "$vVM" ]; then
	if [ $# -eq 1 -a "$1" == "test" ]; then
		./BuildVoltha.sh $1
	else
		# Default to installer mode 
		./BuildVoltha.sh install
	fi
fi

# Install python which is required for ansible
echo -e "${lBlue}Installing python${NC}"
ssh -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no -i key.pem vinstall@$ipAddr sudo apt-get update 
ssh -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no -i key.pem vinstall@$ipAddr sudo apt-get -y install python 

# Make sure the VM is up-to-date
echo -e "${lBlue}Ensure that the VM is up-to-date${NC}"
ssh -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no -i key.pem vinstall@$ipAddr sudo apt-get update 
ssh -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no -i key.pem vinstall@$ipAddr sudo apt-get -y upgrade 



# Copy the apt repository to the VM because it's way too slow using ansible
#echo -e "${red}NOT COPYING${lBlue} the apt-repository to the VM, ${red}TESTING ONLY REMOVE FOR PRODUCTION${NC}"
#echo -e "${lBlue}Copy the apt-repository to the VM${NC}"
#scp -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no -i key.pem -r apt-mirror vinstall@$ipAddr:apt-mirror

# Create the docker.cfg file in the ansible tree using the VMs IP address
echo 'DOCKER_OPTS="$DOCKER_OPTS --insecure-registry '$ipAddr':5000 -H tcp://0.0.0.0:2375 -H unix:///var/run/docker.sock --registry-mirror=http://'$ipAddr':5001"' > ansible/roles/docker/templates/docker.cfg

# Add the voltha vm's information to the ansible tree
echo -e "${lBlue}Add the voltha vm and key to the ansible accessible hosts${NC}"
vIpAddr=`virsh domifaddr voltha_voltha${uId} | tail -n +3 | awk '{ print $4 }' | sed -e 's~/.*~~'`
echo "[voltha]" > ansible/hosts/voltha
echo $vIpAddr >> ansible/hosts/voltha
echo "ansible_ssh_private_key_file: $wd/../.vagrant/machines/voltha${uId}/libvirt/private_key" > ansible/host_vars/$vIpAddr


# Prepare to launch the ansible playbook to configure the installer VM
echo -e "${lBlue}Prepare to launch the ansible playbook to configure the VM${NC}"
echo "[installer]" > ansible/hosts/installer
echo "$ipAddr" >> ansible/hosts/installer
echo "ansible_ssh_private_key_file: $wd/key.pem" > ansible/host_vars/$ipAddr

# Launch the ansible playbook
echo -e "${lBlue}Launching the ansible playbook${NC}"
ansible-playbook ansible/volthainstall.yml -i ansible/hosts/installer
if [ $? -ne 0 ]; then
	echo -e "${red}PLAYBOOK FAILED, Exiting${NC}"
	exit
fi
ansible-playbook ansible/volthainstall.yml -i ansible/hosts/voltha
if [ $? -ne 0 ]; then
	echo -e "${red}PLAYBOOK FAILED, Exiting${NC}"
	exit
fi

if [ $# -eq 1 -a "$1" == "test" ]; then
	echo -e "${lBlue}Testing, the install image ${red}WILL NOT${lBlue} be built${NC}"
else
	echo -e "${lBlue}Building, the install image (this can take a while)${NC}"
	# Create a temporary directory for all the installer files
        mkdir tmp_installer
        cp vmTemplate.xml tmp_installer
	# Shut down the installer vm
	ctr=0
	vStat=`virsh list | grep $iVmName`
	virsh shutdown $iVmName
	while [ ! -z "$vStat" ];
	do
		echo "Waiting for $iVmName to shut down"
		sleep 2
		vStat=`virsh list | grep $iVmName`
		ctr=`expr $ctr + 1`
		if [ $ctr -eq $shutdownTimeout ]; then
			echo -e "${red}Tired of waiting, forcing the VM off${NC}"
			virsh destroy $iVmName
			vStat=`virsh list | grep $iVmName`
		fi
	done
        # Copy the install bootstrap script to the installer directory
        cp BootstrapInstaller.sh tmp_installer
        # Copy the private key to access the VM
        cp key.pem tmp_installer
        pushd tmp_installer > /dev/null 2>&1
        # Copy the vm image to the installer directory
	virsh vol-dumpxml $iVmName.qcow2 default  | sed -e 's/<key.*key>//' | sed -e '/^[ ]*$/d' > ${iVmName}_volume.xml
	virsh pool-create-as installer --type dir --target `pwd`
	virsh vol-create-from installer ${iVmName}_volume.xml $iVmName.qcow2 --inputpool default
	virsh pool-destroy installer
	# The image is copied in as root. It needs to have ownership changed
	# this will result in a password prompt.
	sudo chown `whoami`.`whoami` $iVmName.qcow2
	# Now create the installer tar file
        tar cjf ../$installerArchive .
        popd > /dev/null 2>&1
	# Clean up
	rm -fr tmp_installer
	# Final location for the installer
	rm -fr $installerDirectory
	mkdir $installerDirectory
	cp deployInstaller.sh $installerDirectory
	# Check the image size and determine if it needs to be split.
        # To be safe, split the image into chunks smaller than 2G so that
        # it will fit on a FAT32 volume.
	fSize=`ls -l $installerArchive | awk '{print $5'}`
	if [ $fSize -gt 2000000000 ]; then
		echo -e "${lBlue}Installer file too large, breaking into parts${NC}"
		# The file is too large, breaking it up into parts
		sPos=0
		fnn="00"
		while dd if=$installerArchive of=${installerDirectory}/${installerPart}$fnn \
			bs=1900MB count=1 skip=$sPos > /dev/null 2>&1
		do
			sPos=`expr $sPos + 1`
			if [ ! -s ${installerDirectory}/${installerPart}$fnn ]; then
				rm -f ${installerDirectory}/${installerPart}$fnn
				break
			fi
			if [ $sPos -lt 10 ]; then
				fnn="0$sPos"
			else
				fnn="$sPos"
			fi
		done
	else
		cp $installerArchive $installerDirectory
	fi
	# Clean up
	rm $installerArchive
	echo -e "${lBlue}The install image is built and can be found in ${yellow}$installerDirectory${NC}"
	echo -e "${lBlue}Copy all the files in ${yellow}$installerDirectory${lBlue} to the traasnport media${NC}"
fi