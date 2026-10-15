#!/usr/bin/env ruby
# Revoca el certificado "Apple Development: Created via API" que creó ESTE runner
# (-allowProvisioningUpdates crea uno por runner efímero y Apple tiene tope).
# Identifica por número de serie del keychain local: nunca toca certificados de
# otros runners ni los personales. Solo stdlib (openssl, net/http, json).
# DRY_RUN=1 lista sin revocar.
require 'openssl'
require 'json'
require 'net/http'
require 'base64'

key_id = ENV.fetch('ASC_KEY_ID')
issuer = ENV.fetch('ASC_ISSUER_ID')
key_path = ENV['ASC_KEY_PATH'] || File.expand_path("~/.appstoreconnect/private_keys/AuthKey_#{key_id}.p8")
dry_run = ENV['DRY_RUN'] == '1'
name = ENV['CERT_NAME'] || 'Apple Development: Created via API'

def b64(s)
  Base64.urlsafe_encode64(s, padding: false)
end

def token(key_id, issuer, key_path)
  key = OpenSSL::PKey::EC.new(File.read(key_path))
  now = Time.now.to_i
  signing_input = [b64(JSON.dump(alg: 'ES256', kid: key_id, typ: 'JWT')),
                   b64(JSON.dump(iss: issuer, iat: now, exp: now + 1200, aud: 'appstoreconnect-v1'))].join('.')
  der = key.sign(OpenSSL::Digest.new('SHA256'), signing_input)
  r, s = OpenSSL::ASN1.decode(der).value.map { |v| v.value.to_s(2).rjust(32, "\0") }
  "#{signing_input}.#{b64(r + s)}"
end

def normalize(serial)
  serial.to_s.upcase.sub(/\A0+/, '')
end

pems = `security find-certificate -a -c "#{name}" -p 2>/dev/null`.scan(/-----BEGIN CERTIFICATE-----.+?-----END CERTIFICATE-----/m)
local = pems.map { |pem| normalize(OpenSSL::X509::Certificate.new(pem).serial.to_s(16)) }.uniq
puts "Certificados '#{name}' en el keychain de este runner: #{local.size}"
exit 0 if local.empty?

auth = { 'Authorization' => "Bearer #{token(key_id, issuer, key_path)}" }
http = Net::HTTP.new('api.appstoreconnect.apple.com', 443)
http.use_ssl = true

res = http.get('/v1/certificates?filter[certificateType]=DEVELOPMENT&limit=200&fields[certificates]=serialNumber,displayName', auth)
abort "::warning::No se pudo listar certificados (#{res.code}): #{res.body[0, 300]}" unless res.is_a?(Net::HTTPSuccess)

targets = JSON.parse(res.body)['data'].select { |c| local.include?(normalize(c.dig('attributes', 'serialNumber'))) }
puts "Coinciden en App Store Connect: #{targets.size}"
targets.each do |c|
  if dry_run
    puts "DRY_RUN: revocaría #{c['id']} (#{c.dig('attributes', 'displayName')})"
    next
  end
  del = http.delete("/v1/certificates/#{c['id']}", auth)
  if del.is_a?(Net::HTTPSuccess)
    puts "Revocado #{c['id']}"
  else
    puts "::warning::No se pudo revocar #{c['id']} (#{del.code}): #{del.body[0, 300]}"
  end
end
