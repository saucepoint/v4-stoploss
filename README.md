# v4-stoploss
### **Stop Loss Orders with Uniswap V4 Hooks 🦄**

*"if ETH drops below $1500, market sell my bags"*

Integrated directly into the Uniswap V4 pools, stop loss orders are posted onchain and executed via the `afterSwap()` hook. No external bots or actors are required to guarantee execution.

---

## Use Cases

* Spot traders: protect overnight positions from downside risk

* Leverage traders: use stop loss proceeds to repay loans. Example capital flow found in

* Lending Protocols (advanced): use stop loss orders to *liquidate collateral*. Instead of liquidation bots and external participants, stop losses have guaranteed execution.
    * Note: additional safety is required to ensure that large market orders do not result in bad debt

## Features

* Guaranteed execution. If the pool crosses the triggered tick, the posted capital is guaranteed to market-sell.

* Asynchronous claims on executed orders. Opening a stop loss order provides an ERC-1155 receipt token. Upon successful order execution, the receipt token is exchanged for the proceeds.

* Semi-resistant to flashloan pool manipulation. The choice of `afterSwap()` and opposite-trade execution reduces incentives to create scam wicks.

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


