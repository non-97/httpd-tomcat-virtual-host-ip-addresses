#!/bin/bash

# -x to display the command to be executed
set -xe

# Redirect /var/log/user-data.log and /dev/console
exec > >(tee /var/log/user-data.log | logger -t user-data -s 2>/dev/console) 2>&1

# Install Packages
token=$(curl -X PUT "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 21600")
region_name=$(curl -H "X-aws-ec2-metadata-token: $token" -v http://169.254.169.254/latest/meta-data/placement/availability-zone | sed -e 's/.$//')

dnf install -y "https://s3.${region_name}.amazonaws.com/amazon-ssm-${region_name}/latest/linux_amd64/amazon-ssm-agent.rpm" \
  java-17-openjdk \
  httpd

# SSM Agent
systemctl enable amazon-ssm-agent
systemctl start amazon-ssm-agent

# Wait for eth1 to be found
while true; do
    if nmcli device show eth1 > /dev/null 2>&1; then
        echo "Device 'eth1' found."
        break
    else
        echo "Device 'eth1' not found. waiting 1 second"
        sleep 1
    fi
done

# List IP Address
ip_addrs=($(nmcli device show eth1 \
  | grep IP4.ADDRESS \
  | awk -F "[:/]" '{print $2}' \
  | tr -d ' '))

echo "${ip_addrs[@]}"

# Tomcat 10
# Install
cd /usr/local/
curl https://dlcdn.apache.org/tomcat/tomcat-10/v10.1.13/bin/apache-tomcat-10.1.13.tar.gz -o apache-tomcat-10.1.13.tar.gz
tar zxvf apache-tomcat-10.1.13.tar.gz
rm -rf apache-tomcat-10.1.13.tar.gz

# symbolic link
ln -s apache-tomcat-10.1.13 tomcat
ls -l | grep tomcat

# Add tomcat user
useradd tomcat -M -s /sbin/nologin
id tomcat

mkdir -p ./tomcat/pid/
mkdir -p /var/log/tomcat/
chown tomcat:tomcat -R ./tomcat/
chown tomcat:tomcat -R /var/log/tomcat/
ls -l | grep tomcat
ls -l ./tomcat/

# setenv.sh
tee ./tomcat/bin/setenv.sh << 'EOF'
export CATALINA_OPTS=" \
  -server \
  -Xms512m \
  -Xmx512m \
  -Xss512k \
  -XX:MetaspaceSize=512m \
  -Djava.security.egd=file:/dev/urandom"
export CATALINA_PID=/usr/local/tomcat/pid/tomcat.pid
export CATALINA_OUT=/var/log/tomcat/catalina.out
EOF

# AJP Connector
line_num_comment_start=$(($(grep -n '<Connector protocol="AJP/1.3"' ./tomcat/conf/server.xml | cut -d : -f 1)-1))
line_num_comment_end=$(tail -n +$(($line_num_comment_start)) ./tomcat/conf/server.xml \
  | grep -n '\-\->' \
  | head -n 1 \
  | cut -d : -f 1
)
line_num_comment_end=$(($line_num_comment_end+$line_num_comment_start-1))
sed -i "${line_num_comment_start}d" ./tomcat/conf/server.xml
sed -i "$((${line_num_comment_end}-1))d" ./tomcat/conf/server.xml
sed -i "$((${line_num_comment_end}-3))a \               secretRequired=\"false\"" ./tomcat/conf/server.xml

# Disable HTTP Connector
line_num_comment_start=$(($(grep -n '<Connector port="8080" protocol="HTTP/1.1"' ./tomcat/conf/server.xml | cut -d : -f 1)-1))
line_num_comment_end=$(tail -n +$(($line_num_comment_start)) ./tomcat/conf/server.xml \
  | grep -n '/>' \
  | head -n 1 \
  | cut -d : -f 1
)
line_num_comment_end=$(($line_num_comment_end+$line_num_comment_start))
sed -i "$((${line_num_comment_start}))a \    <\!\-\-" ./tomcat/conf/server.xml 
sed -i "$((${line_num_comment_end}))a \    \-\->" ./tomcat/conf/server.xml 

# Disable localhost
sed -i '/<Host name="localhost"/,/\/Host>/d' ./tomcat/conf/server.xml 
sed -i 's/defaultHost="localhost"/defaultHost="'${ip_addrs[0]}'"/g' ./tomcat/conf/server.xml

# Virtual Host
line_num_engine_end=$(($(grep -n '</Engine>' ./tomcat/conf/server.xml | cut -d : -f 1)))
insert_text=$(cat <<EOF

     <Host name="${ip_addrs[0]}" appBase="hoge"
          unpackWARs="true" autoDeploy="false" >
          <Alias>hoge.web.non-97.net</Alias>
          <Valve className="org.apache.catalina.valves.AccessLogValve" directory="/var/log/tomcat"
               prefix="hoge_access_log" suffix=".log" rotatable="false"
               pattern="%h %l %u %t &quot;%r&quot; %s %b" />
     </Host>

     <Host name="${ip_addrs[1]}" appBase="fuga"
          unpackWARs="true" autoDeploy="false" >
          <Alias>fuga.web.non-97.net</Alias>
          <Valve className="org.apache.catalina.valves.AccessLogValve" directory="/var/log/tomcat"
               prefix="fuga_access_log" suffix=".log" rotatable="false"
               pattern="%h %l %u %t &quot;%r&quot; %s %b" />
     </Host>
EOF
)
awk -v n=$line_num_engine_end \
  -v s="$insert_text" \
    'NR == n {print s} {print}' ./tomcat/conf/server.xml \
  > tmpfile && mv -f tmpfile ./tomcat/conf/server.xml

# logging.properties
# catalina.log
sed -i 's|\${catalina.base}/logs|/var/log/tomcat|g' ./tomcat/conf/logging.properties

# Disable localhost, manager, host-manager
sed -i -E 's/^(2localhost|3manager|4host-manager)/# \1/g' ./tomcat/conf/logging.properties
awk -i inplace '{
  if($0 == "1catalina.org.apache.juli.AsyncFileHandler.maxDays = 90") {
    print "# "$0
    print "1catalina.org.apache.juli.AsyncFileHandler.rotatable = false"
  } else {print $0}
}' ./tomcat/conf/logging.properties
sed -i -E 's/^org.apache.catalina.core.ContainerBase/# &/g' ./tomcat/conf/logging.properties

# Contents
line_num_comment_start=$(($(grep -n 'org.apache.catalina.valves.RemoteAddrValve' ./tomcat/webapps/examples/META-INF/context.xml | cut -d : -f 1)-1))
line_num_comment_end=$(($line_num_comment_start+3))

sed -i "$((${line_num_comment_start}))a <\!\-\-" ./tomcat/webapps/examples/META-INF/context.xml
sed -i "$((${line_num_comment_end}))a \-\->" ./tomcat/webapps/examples/META-INF/context.xml

cp -pr ./tomcat/webapps/ ./tomcat/hoge
cp -pr ./tomcat/webapps/ ./tomcat/fuga

echo "hoge tomcat $(uname -n)" > ./tomcat/hoge/examples/index.html
echo "fuga tomcat $(uname -n)" > ./tomcat/fuga/examples/index.html

rm -rf ./tomcat/webapps/ 

# systemd
tee /etc/systemd/system/tomcat.service << EOF
[Unit]
Description=Apache Tomcat Web Application Container
ConditionPathExists=/usr/local/tomcat
After=syslog.target network.target

[Service]
User=tomcat
Group=tomcat
Type=oneshot
RemainAfterExit=yes

ExecStart=/usr/local/tomcat/bin/startup.sh
ExecStop=/usr/local/tomcat/bin/shutdown.sh

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl list-unit-files --type=service | grep tomcat

systemctl start tomcat
systemctl enable tomcat

# httpd
# Virtual Host
tee /etc/httpd/conf.d/httpd-vhosts.conf << EOF
<VirtualHost ${ip_addrs[0]}:80>
    ServerName hoge.web.non-97.net
    DocumentRoot /var/www/html/hoge

    ProxyPass /tomcat/ ajp://localhost:8009/
    ProxyPassReverse /tomcat/ ajp://localhost:8009/

    <Directory /var/www/html/hoge>
        Options FollowSymLinks
        DirectoryIndex index.html
        AllowOverride All
        Require all granted
    </Directory>

    ErrorLog /var/log/httpd/hoge_error_log
    CustomLog /var/log/httpd/hoge_access_log combined
</VirtualHost>

<VirtualHost ${ip_addrs[1]}:80>
    ServerName fuga.web.non-97.net
    DocumentRoot /var/www/html/fuga

    ProxyPass /tomcat/ ajp://localhost:8009/
    ProxyPassReverse /tomcat/ ajp://localhost:8009/

    <Directory /var/www/html/fuga>
        Options FollowSymLinks
        DirectoryIndex index.html
        AllowOverride All
        Require all granted
    </Directory>

    ErrorLog /var/log/httpd/fuga_error_log
    CustomLog /var/log/httpd/fuga_access_log combined
</VirtualHost>
EOF

# Disable Welcome page
cat /dev/null > /etc/httpd/conf.d/welcome.conf

# Disable Auto Index
sudo mv /etc/httpd/conf.d/autoindex.conf /etc/httpd/conf.d/autoindex.conf.org
sed -i 's/Options Indexes FollowSymLinks/Options FollowSymLinks/g' /etc/httpd/conf/httpd.conf

# Disable UserDir
mv /etc/httpd/conf.d/userdir.conf /etc/httpd/conf.d/userdir.conf.org

tee /etc/httpd/conf.d/security.conf << EOF
# Hide Apache Version
ServerTokens Prod 

# Hide Header X-Powered-By
Header unset "X-Powered-By"

# Hide bunner in Error Page
ServerSignature off

# Deny open outer web resources for protection of Click Jacking attack
Header append X-Frame-Options SAMEORIGIN

# Protection for MIME Sniffing attack
Header set X-Content-Type-Options nosniff 
Header set X-XSS-Protection "1; mode=block"

# Deny HTTP TRACE Method access for protection of Cross-Site Tracing attack
TraceEnable Off
EOF

# Check syntax
httpd -t

# Contents
mkdir -p /var/www/html/hoge
mkdir -p /var/www/html/fuga

echo "hoge $(uname -n)" > /var/www/html/hoge/index.html
echo "fuga $(uname -n)" > /var/www/html/fuga/index.html

systemctl start httpd
systemctl enable httpd

# SELinux
setsebool -P httpd_can_network_connect=true
getsebool -a