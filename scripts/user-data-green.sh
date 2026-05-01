#!/bin/bash
# Green environment bootstrap — Amazon Linux 2023
dnf update -y
dnf install -y nginx

TOKEN=$(curl -s -X PUT "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 60")
INSTANCE_ID=$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/instance-id)
AZ=$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/placement/availability-zone)

cat > /usr/share/nginx/html/index.html <<EOF
<!DOCTYPE html>
<html>
<head>
  <title>Green Environment - v2</title>
  <style>
    body { background: #3B6D11; color: white; font-family: sans-serif;
           text-align: center; padding-top: 100px; margin: 0; }
    h1 { font-size: 4em; margin: 0; }
    .meta { margin-top: 40px; font-size: 1.2em; opacity: 0.85; }
    .version { display: inline-block; padding: 8px 20px; border: 2px solid white;
               border-radius: 8px; margin-top: 20px; font-weight: 500; }
  </style>
</head>
<body>
  <h1>GREEN</h1>
  <div class="version">Application v2.0</div>
  <div class="meta">
    <p>Instance: $INSTANCE_ID</p>
    <p>Availability Zone: $AZ</p>
  </div>
</body>
</html>
EOF

# Health endpoint - file, not directory (the fix we made for Blue)
echo "OK" > /usr/share/nginx/html/health

systemctl enable nginx
systemctl start nginx