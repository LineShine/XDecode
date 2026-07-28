from cryptography.hazmat.primitives.asymmetric import ec


def main():
    private_key = ec.generate_private_key(ec.SECP256K1())
    private_numbers = private_key.private_numbers()
    public_numbers = private_numbers.public_numbers

    private_hex = private_numbers.private_value.to_bytes(32, "big").hex()
    public_hex = (
        public_numbers.x.to_bytes(32, "big")
        + public_numbers.y.to_bytes(32, "big")
    ).hex()

    assert len(private_hex) == 64
    assert len(public_hex) == 128

    print("Save private key, fill to XDecode App:")
    print(private_hex)
    print("\nFill to MixLogConfig.publicKey = ")
    print(public_hex)


if __name__ == "__main__":
    main()
