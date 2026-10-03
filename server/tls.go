package main

import (
	"bufio"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/sha256"
	"crypto/tls"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/hex"
	"encoding/pem"
	"math/big"
	"net"
	"os"
	"path/filepath"
	"time"
)

// CertName is the name baked into the self-signed certificate. The client
// pins the certificate and verifies against this name instead of a hostname,
// so the server works on a bare IP address without a domain.
const CertName = "uno-glass-server"

// loadOrCreateCert returns a TLS config using dir/server.crt + server.key,
// generating a self-signed ECDSA certificate on first run.
func loadOrCreateCert(dir string) (*tls.Config, string, error) {
	certPath := filepath.Join(dir, "server.crt")
	keyPath := filepath.Join(dir, "server.key")
	if _, err := os.Stat(certPath); os.IsNotExist(err) {
		if err := generateCert(certPath, keyPath); err != nil {
			return nil, "", err
		}
	}
	cert, err := tls.LoadX509KeyPair(certPath, keyPath)
	if err != nil {
		return nil, "", err
	}
	sum := sha256.Sum256(cert.Certificate[0])
	cfg := &tls.Config{Certificates: []tls.Certificate{cert}, MinVersion: tls.VersionTLS12}
	return cfg, hex.EncodeToString(sum[:]), nil
}

func generateCert(certPath, keyPath string) error {
	if err := os.MkdirAll(filepath.Dir(certPath), 0o700); err != nil {
		return err
	}
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		return err
	}
	serial, _ := rand.Int(rand.Reader, new(big.Int).Lsh(big.NewInt(1), 120))
	tmpl := &x509.Certificate{
		SerialNumber:          serial,
		Subject:               pkix.Name{CommonName: CertName, Organization: []string{"UNO Glass"}},
		DNSNames:              []string{CertName},
		NotBefore:             time.Now().Add(-time.Hour),
		NotAfter:              time.Now().AddDate(10, 0, 0),
		KeyUsage:              x509.KeyUsageDigitalSignature | x509.KeyUsageCertSign,
		ExtKeyUsage:           []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth},
		BasicConstraintsValid: true,
		IsCA:                  true,
	}
	der, err := x509.CreateCertificate(rand.Reader, tmpl, tmpl, &key.PublicKey, key)
	if err != nil {
		return err
	}
	kb, err := x509.MarshalECPrivateKey(key)
	if err != nil {
		return err
	}
	if err := os.WriteFile(keyPath, pem.EncodeToMemory(&pem.Block{Type: "EC PRIVATE KEY", Bytes: kb}), 0o600); err != nil {
		return err
	}
	return os.WriteFile(certPath, pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: der}), 0o644)
}

// peekConn replays bytes consumed while sniffing the protocol.
type peekConn struct {
	net.Conn
	r *bufio.Reader
}

func (p *peekConn) Read(b []byte) (int, error) { return p.r.Read(b) }

// isLocal reports whether ip is loopback, private (LAN) or link-local.
func isLocal(addr net.Addr) bool {
	host, _, _ := net.SplitHostPort(addr.String())
	ip := net.ParseIP(host)
	return ip != nil && (ip.IsLoopback() || ip.IsPrivate() || ip.IsLinkLocalUnicast())
}

// sniff lets one port serve both TLS and plain clients: a TLS handshake
// starts with 0x16, our JSON protocol with '{'. Plain connections are only
// accepted from the local machine or LAN, so passwords never cross the
// internet unencrypted. With cfg == nil everything is plain.
func sniff(c net.Conn, cfg *tls.Config) (net.Conn, bool) {
	if cfg == nil {
		return c, true
	}
	c.SetReadDeadline(time.Now().Add(15 * time.Second))
	r := bufio.NewReader(c)
	b, err := r.Peek(1)
	c.SetReadDeadline(time.Time{})
	if err != nil {
		c.Close()
		return nil, false
	}
	pc := &peekConn{c, r}
	if b[0] == 0x16 {
		return tls.Server(pc, cfg), true
	}
	if isLocal(c.RemoteAddr()) {
		return pc, true
	}
	c.Close()
	return nil, false
}
