#!/bin/bash
# Blue environment bootstrap — Amazon Linux 2023
dnf update -y
dnf install -y nginx

# Capture instance metadata for the page
TOKEN=$(curl -s -X PUT "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 60")
INSTANCE_ID=$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/instance-id)
AZ=$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/placement/availability-zone)

# Replace the default nginx page
cat > /usr/share/nginx/html/index.html <<EOF
<!DOCTYPE html>
<html>
<head>
  <title>Blue Environment - v1</title>
  <style>
    body { background: #185FA5; color: white; font-family: sans-serif;
           text-align: center; padding-top: 100px; margin: 0; }
    h1 { font-size: 4em; margin: 0; }
    .meta { margin-top: 40px; font-size: 1.2em; opacity: 0.85; }
    .version { display: inline-block; padding: 8px 20px; border: 2px solid white;
               border-radius: 8px; margin-top: 20px; font-weight: 500; }
  </style>
</head>
<body>
  <h1>BLUE</h1>
  <div class="version">Application v1.0</div>
  <div class="meta">
    <p>Instance: $INSTANCE_ID</p>
    <p>Availability Zone: $AZ</p>
  </div>
</body>
</html>
EOF

# Health check endpoint - must return 200 for ALB to consider target healthy
echo "OK" > /usr/share/nginx/html/health

systemctl enable nginx
systemctl start nginx