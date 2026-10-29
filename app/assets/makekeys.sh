#!/bin/bash
set -e

echo "🧹 Cleaning up old certificates and config files..."
rm -f ca.key ca.pem ca.srl key.pem server.csr cert.pem client-identity.pfx ext.cnf

echo "🔐 Generating Root CA private key..."
openssl genrsa -out ca.key 4096

echo "📜 Issuing Root CA certificate (1000-year validity)..."
openssl req -x509 -new -nodes -key ca.key -sha256 -days 365000 -out ca.pem -subj "/CN=SilvaneOS Root CA"

echo "⚙️ Creating localhost SAN configuration..."
echo "subjectAltName = DNS:localhost" > ext.cnf

echo "🔑 Generating server private key..."
openssl genrsa -out key.pem 4096

echo "📝 Generating server CSR..."
openssl req -new -key key.pem -out server.csr -subj "/CN=localhost"

echo "✍️ Signing server certificate with Root CA and SAN..."
openssl x509 -req -in server.csr -CA ca.pem -CAkey ca.key -CAcreateserial -out cert.pem -days 365000 -sha256 -extfile ext.cnf

echo "📦 Exporting mTLS client certificate bundle (client-identity.pfx)..."
openssl pkcs12 -export -out client-identity.pfx -inkey key.pem -in cert.pem -certfile ca.pem -passout pass:SilvaneOS

echo "🔍 Verifying generated certificate validity dates:"
openssl x509 -in cert.pem -noout -dates

echo "✨ All certificates successfully generated!"