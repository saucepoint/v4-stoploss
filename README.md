# v4-stoploss
### **Stop Loss Orders with Uniswap V4 Hooks 🦄**

*"if ETH drops below $1500, market sell my bags"*

[![Tests](https://github.com/saucepoint/v4-stoploss/actions/workflows/tests.yml/badge.svg)](https://github.com/saucepoint/v4-stoploss/actions/workflows/tests.yml)

Integrated directly into the Uniswap V4 pools, stop loss orders are posted onchain and executed via the `afterSwap()` hook. No external bots or actors are required to guarantee execution.

![image](https://github.com/saucepoint/v4-stoploss/assets/98790946/bf049297-2629-48bb-a0bd-8be22f6ace13)


---

## Use Cases

* <ins>Spot traders</ins>: protect overnight positions from downside risk

* <ins>Leverage traders</ins>: use stop loss proceeds to repay loans. Please see [examples/README.md](examples/README.md) for usage

* <ins>Lending Protocols (advanced)</ins>: use stop loss orders to *liquidate collateral*. Instead of liquidation bots and external participants, stop losses offer guaranteed execution
    * Note: additional safety is required to ensure that large market orders do not result in bad debt

## Features

* Guaranteed execution -- if the pool crosses the user-specified tick, the posted capital is guaranteed to market-sell

* Asynchronous claims -- opening a stop loss order provides an ERC-1155 receipt token. Upon successful order execution, the receipt token is exchanged for the proceeds

* Generic, reusable Hook -- the hook is deployed once, new pools can utilize the already-deployed hook

---

Additional resources:

[v4-periphery](https://github.com/uniswap/v4-periphery) and [LimitOrder.sol](https://github.com/Uniswap/v4-periphery/blob/main/contracts/hooks/examples/LimitOrder.sol)

[v4-core](https://github.com/uniswap/v4-core)

---

*requires [foundry](https://book.getfoundry.sh)*

```shell
# tests require a local mainnet fork
forge test --fork-url https://eth.llamarpc.com
```


