#!/bin/bash

LOGFILE="/var/log/install_jenkins.log"

# Function to check if a command was successful
check_success() {
  if [ $? -ne 0 ]; then
    echo "Error: $1" | tee -a $LOGFILE
    exit 1
  fi
}

# Step 1: Update the system
echo "Updating the system..." | tee -a $LOGFILE
sudo dnf update -y | tee -a $LOGFILE
check_success "Failed to update the system"

# Step 2: Install Java
echo "Installing Java..." | tee -a $LOGFILE
sudo dnf install -y java-11-openjdk-devel | tee -a $LOGFILE
check_success "Failed to install Java"

# Ensure Java 11 is set as the default version
echo "Setting Java 11 as the default version..." | tee -a $LOGFILE
sudo alternatives --set java /usr/lib/jvm/java-11-openjdk-11*/bin/java | tee -a $LOGFILE
check_success "Failed to set Java 11 as default"

# Step 3: Configure the Jenkins repository
echo "Configuring the Jenkins repository..." | tee -a $LOGFILE
sudo wget -O /etc/yum.repos.d/jenkins.repo http://pkg.jenkins-ci.org/redhat-stable/jenkins.repo | tee -a $LOGFILE
check_success "Failed to configure the Jenkins repository"
sudo rpm --import https://pkg.jenkins.io/redhat-stable/jenkins.io.key | tee -a $LOGFILE
check_success "Failed to import the Jenkins repository GPG key"

# Step 4: Install Jenkins
echo "Installing Jenkins..." | tee -a $LOGFILE
sudo dnf install -y jenkins | tee -a $LOGFILE
check_success "Failed to install Jenkins"

# Step 5: Configure the firewall
echo "Configuring the firewall..." | tee -a $LOGFILE
sudo firewall-cmd --permanent --zone=public --add-port=8080/tcp | tee -a $LOGFILE
check_success "Failed to configure the firewall"
sudo firewall-cmd --reload | tee -a $LOGFILE
check_success "Failed to reload the firewall"

# Step 6: Configure the /etc/sysconfig/jenkins file
echo "Configuring /etc/sysconfig/jenkins..." | tee -a $LOGFILE
sudo tee /etc/sysconfig/jenkins > /dev/null <<EOL
# Configuration file for Jenkins

# The Jenkins home directory
JENKINS_HOME="/var/lib/jenkins"

# The default user to run Jenkins as
JENKINS_USER="jenkins"
JENKINS_GROUP="jenkins"

# Port Jenkins is listening on
JENKINS_PORT="8080"

# Java executable to use
JENKINS_JAVA_CMD="/usr/bin/java"

# Java options
JENKINS_JAVA_OPTIONS="-Djava.awt.headless=true"

# Jenkins options
JENKINS_ARGS=""

# Location of the Jenkins war file
JENKINS_WAR="/usr/lib/jenkins/jenkins.war"

# JAVA_HOME
JAVA_HOME="/usr/lib/jvm/java-11-openjdk"
EOL
check_success "Failed to configure /etc/sysconfig/jenkins"

# Verify Jenkins directory permissions
echo "Verifying Jenkins directory permissions..." | tee -a $LOGFILE
sudo chown -R jenkins:jenkins /var/lib/jenkins | tee -a $LOGFILE
check_success "Failed to adjust permissions for /var/lib/jenkins"

sudo mkdir -p /var/log/jenkins | tee -a $LOGFILE
sudo chown -R jenkins:jenkins /var/log/jenkins | tee -a $LOGFILE
check_success "Failed to create and adjust permissions for /var/log/jenkins"

sudo mkdir -p /var/cache/jenkins | tee -a $LOGFILE
sudo chown -R jenkins:jenkins /var/cache/jenkins | tee -a $LOGFILE
check_success "Failed to create and adjust permissions for /var/cache/jenkins"

# Step 7: Start and enable Jenkins
echo "Starting Jenkins..." | tee -a $LOGFILE
sudo systemctl daemon-reload | tee -a $LOGFILE
sudo systemctl start jenkins | tee -a $LOGFILE
if [ $? -ne 0 ]; then
  echo "Error: Failed to start Jenkins. Checking logs..." | tee -a $LOGFILE
  sudo journalctl -xe | tail -n 20 | tee -a $LOGFILE
  exit 1
fi

sudo systemctl enable jenkins | tee -a $LOGFILE
check_success "Failed to enable Jenkins to start on boot"

# Verify Jenkins service status
sudo systemctl status jenkins | tee -a $LOGFILE
sudo systemctl status jenkins | grep "active (running)" | tee -a $LOGFILE
check_success "Jenkins is not running correctly"

# Display initial administrator password
echo "Jenkins installed and running successfully. The initial administrator password is:" | tee -a $LOGFILE
sudo cat /var/lib/jenkins/secrets/initialAdminPassword | tee -a $LOGFILE

echo "Jenkins installation and configuration completed successfully." | tee -a $LOGFILE
