# vetoken

A reference implementation of VeToken.

## Reminder

Currently, there is no way to represent a rabasing token on Aptos, due to the design
of Aptos Coin Standard. Potentially the Fungible Asset Standard could support this by
allowing overriding the default `transfer` and `balance` behavior of a coin.
