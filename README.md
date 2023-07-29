# Vote Escrowed Token (veToken)

This repo is a reference implementation of veToken, which represents a specific duration locked token. A user, for example, can lock a token for a certain number of epochs, during which they are non spendable. The tokens become available or "unlock" after the specified epochs pass. Users can also delegate their token balance to other accounts. A sample utility could include additional governance power to vote escrowed token holders. 

This implementation was built by Thala Labs and is the source for vote escrowed THL or veTHL. 

## Reminder

Currently, there is no way to represent a rebasing token on Aptos, due to the design
of Aptos Coin Standard. The Fungible Asset Standard could potentially support this by
allowing overriding the default `transfer` and `balance` behavior of a coin.
