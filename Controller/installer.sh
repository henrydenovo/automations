#!/bin/bash

# Function to display progress
function show_progress {
  step=$1
  total_steps=$2
  message=$3
  progress=$((step * 100 / total_steps))
  echo "[$progress%] $message"
}

# Function to clean up created files and directories
function cleanup {
  echo "Cleaning up created files and directories..."
  sudo systemctl stop celerate-controller || true
  sudo systemctl disable celerate-controller || true
  sudo rm -rf /home/controller/controllerBundle
  sudo rm -rf /home/controller/external-controller
  sudo rm -rf /home/controller/celerate-controller.tar.gz
  sudo rm -rf /etc/systemd/system/celerate-controller.service
  sudo userdel -r controller || true
  sudo yum remove -y mongodb-enterprise nginx certbot python3-certbot-nginx || true
  sudo rm -rf /etc/nginx/sites-available /etc/nginx/sites-enabled /etc/letsencrypt
}

# Function to handle errors
function handle_error {
  step=$1
  last_command=$2
  echo "Error occurred in step: $step. Last command: $last_command"
  sudo systemctl status celerate-controller
  sudo journalctl -u celerate-controller --no-pager -n 50
  echo "Do you want to retry the step '$step'? (yes/no)"
  read retry
  if [ "$retry" == "yes" ]; then
    echo "Retrying step '$step'..."
    eval "$last_command"
  else
    cleanup
    exit 1
  fi
}

# Trap errors
trap 'handle_error "$current_step" "$BASH_COMMAND"' ERR

# Total number of steps
total_steps=24

# Validate the existence of external-controller.tar.gz, database.zip, and repos.zip
if [[ ! -f "./assets/external-controller.tar.gz" ]]; then
  echo "Error: external-controller.tar.gz not found in the assets directory."
  exit 1
fi

if [[ ! -f "./assets/database.zip" ]]; then
  echo "Error: database.zip not found in the assets directory."
  exit 1
fi

if [[ ! -f "./assets/repos.zip" ]]; then
  echo "Error: repos.zip not found in the assets directory."
  exit 1
fi

# Ask for the domain name
read -p "Enter the domain name (without .furtherreach.net): " DOMAIN_NAME
DOMAIN="${DOMAIN_NAME}.furtherreach.net"

# Step 1: Ensure a valid repository is available and update packages
current_step="Ensuring a valid repository and updating packages"
show_progress 1 $total_steps "$current_step..."
rm -rf /etc/yum.repos.d/CentOS-Linux-AppStream.repo
rm -rf /etc/yum.repos.d/CentOS-Linux-BaseOS.repo

if [[ ! -f /etc/pki/rpm-gpg/RPM-GPG-KEY-EPEL-8 ]]; then
  sudo curl -o /etc/pki/rpm-gpg/RPM-GPG-KEY-EPEL-8 https://dl.fedoraproject.org/pub/epel/RPM-GPG-KEY-EPEL-8
fi
sudo yum install -y epel-release
sudo yum install -y unzip tar
unzip -o ./assets/repos.zip -d /etc/yum.repos.d/
sudo yum update -y

# Step 2: Clean up previous installations if any
current_step="Cleaning up previous installations"
show_progress 2 $total_steps "$current_step..."
cleanup

# Step 3: Ensure controller user
current_step="Ensuring controller user"
show_progress 3 $total_steps "$current_step..."
if id "controller" &>/dev/null; then
    echo "User 'controller' already exists."
else
    sudo useradd -m -s /bin/bash -d /home/controller controller
fi

# Step 4: Configure MongoDB repository
current_step="Configuring MongoDB repository"
show_progress 4 $total_steps "$current_step..."
sudo rm -f /etc/yum.repos.d/mongodb-enterprise-4.4.repo
cat <<EOL | sudo tee /etc/yum.repos.d/mongodb-enterprise-4.4.repo
[mongodb-enterprise-4.4]
name=MongoDB Enterprise Repository
baseurl=https://repo.mongodb.com/yum/redhat/\$releasever/mongodb-enterprise/4.4/\$basearch/
gpgcheck=1
enabled=1
gpgkey=https://www.mongodb.org/static/pgp/server-4.4.asc
EOL

# Step 5: Install MongoDB Enterprise
current_step="Installing MongoDB Enterprise"
show_progress 5 $total_steps "$current_step..."
sudo yum --disableexcludes=all install -y mongodb-enterprise

# Step 6: Exclude MongoDB from auto-updates
current_step="Excluding MongoDB from auto-updates"
show_progress 6 $total_steps "$current_step..."
echo "exclude=mongodb-enterprise,mongodb-enterprise-server,mongodb-enterprise-shell,mongodb-enterprise-mongos,mongodb-enterprise-tools" | sudo tee -a /etc/yum.conf

# Step 7: Configure SELinux in permissive mode
current_step="Configuring SELinux in permissive mode"
show_progress 7 $total_steps "$current_step..."
sudo setenforce 0
sudo sed -i 's/^SELINUX=enforcing/SELINUX=permissive/' /etc/selinux/config

# Step 8: Configure MongoDB port
current_step="Configuring MongoDB port"
show_progress 8 $total_steps "$current_step..."
sudo yum install -y policycoreutils-python-utils
sudo semanage port -a -t mongod_port_t -p tcp 3001

# Step 9: Configure MongoDB
current_step="Configuring MongoDB"
show_progress 9 $total_steps "$current_step..."
sudo sed -i 's/^  port: 27017/  port: 3001/' /etc/mongod.conf
sudo systemctl enable mongod
sudo systemctl start mongod

# Step 10: Add domain to /etc/hosts (for local testing)
current_step="Adding domain to /etc/hosts for local testing"
show_progress 10 $total_steps "$current_step..."
sudo sh -c "echo '127.0.0.1 $DOMAIN www.$DOMAIN' >> /etc/hosts"

# Step 11: Install Certbot and obtain SSL certificates
current_step="Installing Certbot and obtaining SSL certificates"
show_progress 11 $total_steps "$current_step..."
sudo yum install -y certbot python3-certbot-nginx
sudo firewall-cmd --permanent --add-service=http
sudo firewall-cmd --permanent --add-service=https
sudo firewall-cmd --reload
if ! sudo certbot certonly --standalone -d $DOMAIN -d www.$DOMAIN; then
    echo "Certbot failed. Generating self-signed certificate..."
    sudo mkdir -p /etc/letsencrypt/live/$DOMAIN
    sudo openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
        -keyout /etc/letsencrypt/live/$DOMAIN/privkey.pem \
        -out /etc/letsencrypt/live/$DOMAIN/fullchain.pem \
        -subj "/CN=$DOMAIN"
fi

# Step 12: Install NGINX
current_step="Installing NGINX"
show_progress 12 $total_steps "$current_step..."
sudo yum install -y nginx
sudo mkdir -p /etc/nginx/sites-available /etc/nginx/sites-enabled
sudo sed -i '/http {/a include /etc/nginx/sites-enabled/*.conf;\nserver_names_hash_bucket_size 64;' /etc/nginx/nginx.conf

cat <<EOL | sudo tee /etc/nginx/sites-available/controller.conf
server {
    listen 80;
    server_name $DOMAIN;
    if (\$host !~ ^($DOMAIN)\$ ) {
        return 444;
    }
    root /usr/share/nginx/html/;
    location / {
        return 301 https://\$host\$request_uri;
    }
}
server {
    listen 443 ssl;
    server_name $DOMAIN;
    ssl_certificate /etc/letsencrypt/live/$DOMAIN/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$DOMAIN/privkey.pem;
    ssl_session_timeout 5m;
    ssl_protocols TLSv1 TLSv1.1 TLSv1.2;
    ssl_ciphers HIGH:!aNULL:!MD5;
    ssl_prefer_server_ciphers on;
    location / {
        proxy_pass http://localhost:3000;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
    }
    error_page 500 502 503 504 /50x.html;
    location = /50x.html {
        root /usr/share/nginx/html;
    }
}
EOL
sudo ln -s /etc/nginx/sites-available/controller.conf /etc/nginx/sites-enabled/
sudo systemctl enable nginx
sudo systemctl start nginx || handle_error "Installing NGINX" "sudo systemctl start nginx"

# Step 13: Extract and configure the application
current_step="Extracting and configuring the application"
show_progress 13 $total_steps "$current_step..."
sudo mkdir -p /home/controller/controllerBundle
sudo tar -xzvf ./assets/external-controller.tar.gz -C /home/controller/controllerBundle --strip-components=1
sudo chown -R controller:controller /home/controller/controllerBundle

# Step 14: Install NVM and Node.js
current_step="Installing NVM and Node.js"
show_progress 14 $total_steps "$current_step..."
sudo -u controller bash << EOF
curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.38.0/install.sh | bash
source /home/controller/.nvm/nvm.sh
nvm install 12.20.1
nvm use 12.20.1
EOF

# Step 15: Check for and install Node.js dependencies
current_step="Checking and installing Node.js dependencies"
show_progress 15 $total_steps "$current_step..."
sudo -u controller bash << EOF
source /home/controller/.nvm/nvm.sh
nvm use 12.20.1
cd /home/controller/controllerBundle/programs/server

# Manually install each dependency
dependencies=(
  "reify@0.20.12"
  "fibers@4.0.3"
  "bcrypt@5.0.1"
  "meteor-node-stubs@1.0.1"
  "node-gyp@6.0.1"
  "meteor-promise@0.8.7"
  "promise@8.0.2"
  "@babel/parser@7.9.4"
  "@types/underscore@1.9.2"
  "underscore@1.9.1"
  "semver@5.4.1"
  "source-map-support@https://github.com/meteor/node-source-map-support/tarball/1912478769d76e5df4c365e147f25896aee6375e"
  "@types/semver@5.4.0"
  "node-pre-gyp@0.14.0"
)

for dependency in "\${dependencies[@]}"; do
  npm install "\$dependency" || exit 1
done

# Verify installation of all dependencies
if ! npm install; then
    echo "Failed to install Node.js dependencies. Checking missing dependencies..."
    npm list || exit 1
fi
EOF

# Step 16: Configure the celerate-controller service
current_step="Configuring the celerate-controller service"
show_progress 16 $total_steps "$current_step..."
cat <<EOL | sudo tee /etc/systemd/system/celerate-controller.service
[Unit]
Description=Celerate Controller
After=network.target

[Service]
Type=simple
User=controller
ExecStart=/home/controller/.nvm/versions/node/v12.20.1/bin/node main.js
Restart=on-failure
WorkingDirectory=/home/controller/controllerBundle
Environment=MONGO_URL=mongodb://localhost:3001/meteor
Environment=ROOT_URL=http://$DOMAIN
Environment=PORT=3000
EnvironmentFile=/etc/systemd/system/meteor-settings.js

[Install]
WantedBy=multi-user.target
EOL

# Step 17: Create meteor-settings.js file
current_step="Creating meteor-settings.js file"
show_progress 17 $total_steps "$current_step..."
cat <<EOL | sudo tee /etc/systemd/system/meteor-settings.js
MONGO_URL=mongodb://localhost:3001/meteor
METEOR_SETTINGS='{"monti":{"appId":"Pq9ERvEgoYsi4TStS","appSecret":"eb50ac62-675a-4efc-af96-4682f5738caa"},"smtp":{"address":"billing@furtherreach.net","password":"Gt7e7YT8bnizdsskoms","server":"smtp.googlemail.com","port":465},"stripe":{"privateKey":"sk_live_VXCWLachZSLF077urCVsI6bGC88"},"aws":{"region": "us-west-2","accessKeyId":"AKIAASsaI7RYX2IIVBFHGSCA","secretAccessKey":"aCsas3RyKk0ti2cD9vMCR/BQtxr28qMJcRRhKwqLZrv","backupsBucket":"celerate-external-controller-backups","fileCollectionsBucket":"file-collections","customerAgreementBucket":"celerate-controller-customeragreement"},"serviceAuth":{"google":{"name":"google","clientId":"620166198276-i33qqs7a0cs2kug4edttirga6ki0o4j0.apps.googleusercontent.com","secret":"tjjGkOUIuEp9e6xs2HC5x7qL","redirectURL":"https://cluster-150-194.furtherreach.net/_oauth/google?close"}},"serverAuthToken":{"encryptionKey":"qrEsY9ZDas9Vey+bR+c05N1g==","MACKey":"hYZUzznZSasvkd9Mq6nr13Yg==","tokenDaysValid":31,"encryptionMode":"AES-128-CTR","hashMode":"sha1"},"sentry":{"dsn":"https://5aae6aa452334683a705253sa3209f7949:93c00a325af14547a2d265f7949060a4@app.getsentry.com/35356"},"uservoice": {"key": "A47zHeLkDBiDJas0VnEymNA","secret": "xlBsx5DYsaD1yfXPtoRRyzuKOwjJVitwUICy7JQJs3M"},"slack":{"token":"xoxb-86984682sa0sa693-889064688823-AVdiJrwPNA58WI6CRT42xKdU","suspendSubscriberChannel":"system-constroller-events"},"logPath": "/home/controller/controllerBundle/logs","public":{"sentry":{"dsn":"https://4e897d3edf5948bsesaae0b79c120cd9cc5@app.getsentry.com/35355"},"stripe":{"publicKey":"pk_live_lxkU6hX3sdasadxvjDwdukbDY5MkC3"},"google":{"mapsApiKey":"AIsadzadsaSyDEpwdkAnDYujwCbX0KTfGjlpfn0krBR7g"},"urls":{"deviceUtility":"https://rhel-prod-deviceutil.furtherreach.net/","customerPortal":"https://portal.furtherreach.net/","externalController":"https://cluster-150-194.furtherreach.net/","icingaService":"https://celerate-icinga.furtherreach.net/","smokepingService":"https://celerate-smokeping.furtherreach.net/","uispService":"https://celerate-uisp.furtherreach.net/","remoteInstall":"https://rhel-prod-remote-install.furtherreach.net/"},"serverType":{"isStaging":true},"productionServer":{"domainName":"cluster-150-194.furtherreach.net"},"ticketingAdmin":{"main":"support@furtherreach.net","all":["support@furtherreach.net","billing@furtherreach.net"],"agents": ["support@furtherreach.net","testuser@denovogroup.org","vishal@furtherreach.net","vishal@denovogroup.org","yahel@denovogroup.org","vivek@denovogroup.org","jasper@denovogroup.org","khill@denovogroup.org","karnel@denovogroup.org","sunil@denovogroup.org","aurelien@denovogroup.org","lauralynn@denovogroup.org","nathan@denovogroup.org"],"specialSenders": ["MAILER-DAEMON@us-west-2.amazonses.com","no-reply@telzio.com"]},"preseem":{"isDisabled": true,"user": "a2fea1654d2795f3c98634b421943ce9c9a65260f55a68cb6a46ac82ba4d5a9f","password": ""}}}'
EOL

# Step 18: Enable and start the celerate-controller service
current_step="Enabling and starting the celerate-controller service"
show_progress 18 $total_steps "$current_step..."
sudo systemctl enable celerate-controller
sudo systemctl start celerate-controller || handle_error "Enabling and starting the celerate-controller service" "sudo systemctl start celerate-controller"

# Step 19: Verify installation
current_step="Verifying installation"
show_progress 19 $total_steps "$current_step..."
if ! sudo systemctl status celerate-controller; then
    echo "Service failed to start. Checking logs..."
    sudo journalctl -u celerate-controller --no-pager -n 50
    handle_error "Verifying installation" "sudo systemctl status celerate-controller"
fi

# Step 20: Extract the database
current_step="Extracting the database"
show_progress 20 $total_steps "$current_step..."
unzip -o ./assets/database.zip -d /tmp
mongorestore --port 3001 --db meteor /tmp/meteor/meteor

# Step 21: Set up auto-renewal for Certbot
current_step="Setting up auto-renewal for Certbot"
show_progress 21 $total_steps "$current_step..."
sudo crontab -l | { cat; echo "0 0,12 * * * python -c 'import random; import time; time.sleep(random.random() * 3600)' && certbot renew --quiet"; } | sudo crontab -

# Step 22: Configure firewall to allow port 3000
current_step="Configuring firewall to allow port 3000"
show_progress 22 $total_steps "$current_step..."
sudo firewall-cmd --permanent --add-port=3000/tcp
sudo firewall-cmd --reload


# Step 23: Clean up temporary files
current_step="Cleaning up temporary files"
show_progress 23 $total_steps "$current_step..."
rm -rf /tmp/meteor

# Step 24: Finish
current_step="Finishing installation"
show_progress 24 $total_steps "$current_step..."
echo "Installation complete."

