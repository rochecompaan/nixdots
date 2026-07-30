package daemon

import (
	"crypto/rand"
	"io"
	"math/big"
	"time"
)

func RandomJitter(source io.Reader) func(time.Duration) time.Duration {
	if source == nil {
		source = rand.Reader
	}
	return func(limit time.Duration) time.Duration {
		if limit <= 0 {
			return 0
		}
		value, err := rand.Int(source, big.NewInt(int64(limit)+1))
		if err != nil {
			return 0
		}
		return time.Duration(value.Int64())
	}
}
