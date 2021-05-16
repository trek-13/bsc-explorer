# bsc-explorer
 Binance Smart Chain Explorer based on Blockscout fork.
 
 
 
# Explorer for Binance Smart Chain
This is a project fork from [Blockscout](https://github.com/poanetwork/blockscout). Use for [Binance Smart Chain Rialto Network](https://explorer.binance.org/smart-testnet).

## Disclaimer
**The software and related documentation are under active development, all subject to potential future change without notification and not ready for production use. The code and security audit have not been fully completed and not ready for any bug bounty.**

## About BlockScout

BlockScout is an Elixir application that allows users to search transactions, view accounts and balances, and verify smart contracts on the Ethereum network including all forks and sidechains.

Currently available full-featured block explorers (Etherscan, Etherchain, Blockchair) are closed systems which are not independently verifiable.  As Ethereum sidechains continue to proliferate in both private and public settings, transparent, open-source tools are needed to analyze and validate transactions.

## License

[![License: GPL v3.0](https://img.shields.io/badge/License-GPL%20v3-blue.svg)](https://www.gnu.org/licenses/gpl-3.0)

This project is licensed under the GNU General Public License v3.0. See the [LICENSE](LICENSE) file for details.


## How To Install

Follow the instructions: `https://docs.blockscout.com/for-developers/manual-deployment`

#### Install PostgreSQL

#### Install Rust

```
sudo apt-get install curl screen
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh
```

#### Install Erlang and Elixir

```
sudo apt-get install gnupg gnupg1 gnupg2
wget https://packages.erlang-solutions.com/erlang-solutions_2.0_all.deb && sudo dpkg -i erlang-solutions_2.0_all.deb
sudo apt-get update
sudo apt-get install esl-erlang
sudo apt-get install elixir
```

#### Install deps

```
apt-get git
apt-get install build-essential autoconf make cmake libssl-dev libtool

mix do deps.get, local.rebar --force, deps.compile, compile
```

#### Install npm and webpack

```
curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.35.3/install.sh | bash
export NVM_DIR="$([ -z "${XDG_CONFIG_HOME-}" ] && printf %s "${HOME}/.nvm" || printf %s "${XDG_CONFIG_HOME}/nvm")"
[ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"

nvm i 12
nvm use 12
npm i

npm install -g webpack
```


