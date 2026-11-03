package yggnode

import (
	"crypto/ed25519"
	"encoding/hex"
	"net"
	"testing"

	"github.com/yggdrasil-network/yggdrasil-go/src/address"
)

func TestFixedSeedAddressVector(t *testing.T) {
	seed := make([]byte, ed25519.SeedSize)
	priv := ed25519.NewKeyFromSeed(seed)
	pub := priv.Public().(ed25519.PublicKey)
	addr := address.AddrForKey(pub)
	t.Logf("seed=%s", hex.EncodeToString(seed))
	t.Logf("publicKey=%s", hex.EncodeToString(pub))
	t.Logf("address=%s", net.IP(addr[:]).String())
}
