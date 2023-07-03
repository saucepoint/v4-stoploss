// SPDX-License-Identifier: MIT
pragma solidity ^0.8.15;

import {ERC1155} from "solmate/tokens/ERC1155.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {IHooks} from "@uniswap/v4-core/contracts/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/contracts/libraries/Hooks.sol";
import {BaseHook} from "v4-periphery/BaseHook.sol";
import {IPoolManager} from "@uniswap/v4-core/contracts/interfaces/IPoolManager.sol";
import {PoolId} from "@uniswap/v4-core/contracts/libraries/PoolId.sol";
import {BalanceDelta} from "@uniswap/v4-core/contracts/types/BalanceDelta.sol";
import {CurrencyLibrary, Currency} from "@uniswap/v4-core/contracts/libraries/CurrencyLibrary.sol";
import {TickMath} from "@uniswap/v4-core/contracts/libraries/TickMath.sol";
import {UniV4UserHook} from "./utils/UniV4UserHook.sol";
import {FixedPointMathLib} from "solmate/utils/FixedPointMathLib.sol";
import {GeomeanOracle} from "v4-periphery/hooks/examples/GeomeanOracle.sol";
import "forge-std/Test.sol";

contract StopLoss is UniV4UserHook, ERC1155, Test {
    using FixedPointMathLib for uint256;
    using PoolId for IPoolManager.PoolKey;
    using CurrencyLibrary for Currency;

    mapping(bytes32 poolId => int24 tickLower) public tickLowerLasts;
    mapping(bytes32 poolId => int24 twapTick) public twapTicks;
    mapping(bytes32 poolId => mapping(int24 tick => mapping(bool zeroForOne => int256 amount))) public stopLossPositions;

    // -- 1155 state -- //
    mapping(uint256 tokenId => TokenIdData) public tokenIdIndex;
    mapping(uint256 tokenId => bool) public tokenIdExists;
    mapping(uint256 tokenId => uint256 claimable) public claimable;
    mapping(uint256 tokenId => uint256 supply) public totalSupply;

    struct TokenIdData {
        IPoolManager.PoolKey poolKey;
        int24 tickLower;
        bool zeroForOne;
    }

    GeomeanOracle public immutable oracleHook;

    // constants for sqrtPriceLimitX96 which allow for unlimited impact
    // (stop loss *should* market sell regardless of market depth 🥴)
    uint160 public constant MIN_PRICE_LIMIT = TickMath.MIN_SQRT_RATIO + 1;
    uint160 public constant MAX_PRICE_LIMIT = TickMath.MAX_SQRT_RATIO - 1;

    constructor(IPoolManager _poolManager, GeomeanOracle oracle) UniV4UserHook(_poolManager) {
        oracleHook = oracle;
    }

    function getHooksCalls() public pure override returns (Hooks.Calls memory) {
        return Hooks.Calls({
            beforeInitialize: false,
            afterInitialize: true,
            beforeModifyPosition: false,
            afterModifyPosition: false,
            beforeSwap: false,
            afterSwap: true,
            beforeDonate: false,
            afterDonate: false
        });
    }

    function afterInitialize(address, IPoolManager.PoolKey calldata key, uint160, int24 tick)
        external
        override
        poolManagerOnly
        returns (bytes4)
    {
        setTickLowerLast(key.toId(), getTickFloor(tick, key.tickSpacing));
        return StopLoss.afterInitialize.selector;
    }

    function afterSwap(
        address,
        IPoolManager.PoolKey calldata key,
        IPoolManager.SwapParams calldata params,
        BalanceDelta
    ) external override returns (bytes4) {
        int24 prevTick = twapTicks[key.toId()];
        int24 currentTick = latestTwapTick(key);
        if (currentTick == prevTick) return StopLoss.afterSwap.selector;

        // effects: update twapTick
        twapTicks[key.toId()] = currentTick;

        int24 tick;
        int24 endTick;
        bool fillZeroForOne;

        if (prevTick < currentTick) {
            // price of currency1 went up
            // therefore, fill stop losses for currency0-sells (zeroForOne positions)
            tick = getTickCeil(prevTick, key.tickSpacing);
            endTick = getTickFloor(currentTick, key.tickSpacing);
            fillZeroForOne = true;
        } else {
            // price of currency1 went down
            // therefore, fill stop losses for currency1-sells (non-zeroForOne positions)
            tick = getTickFloor(currentTick, key.tickSpacing);
            endTick = getTickCeil(prevTick, key.tickSpacing);
            fillZeroForOne = false;
        }

        int256 swapAmounts; // avoid initializing within loop
        while (tick != endTick) {
            swapAmounts = stopLossPositions[key.toId()][tick][fillZeroForOne];
            if (swapAmounts > 0) {
                fillStopLoss(key, tick, fillZeroForOne, swapAmounts);
            }
            unchecked {
                if (fillZeroForOne) {
                    tick += key.tickSpacing;
                } else {
                    tick -= key.tickSpacing;
                }
            }
        }
        return StopLoss.afterSwap.selector;
    }

    function fillStopLoss(IPoolManager.PoolKey calldata poolKey, int24 triggerTick, bool zeroForOne, int256 swapAmount)
        internal
    {
        IPoolManager.SwapParams memory stopLossSwapParams = IPoolManager.SwapParams({
            zeroForOne: zeroForOne,
            amountSpecified: swapAmount,
            sqrtPriceLimitX96: zeroForOne ? MIN_PRICE_LIMIT : MAX_PRICE_LIMIT
        });
        BalanceDelta delta = UniV4UserHook.swap(poolKey, stopLossSwapParams, address(this));
        stopLossPositions[poolKey.toId()][triggerTick][zeroForOne] -= swapAmount;

        // capital from the swap is redeemable by position holders
        uint256 tokenId = getTokenId(poolKey, triggerTick, zeroForOne);

        // TODO: safe casting
        // balance delta returned by .swap(): negative amount indicates outflow from pool (and inflow into contract)
        // therefore, we need to invert
        uint256 amount = zeroForOne ? uint256(int256(-delta.amount1())) : uint256(int256(-delta.amount0()));
        claimable[tokenId] += amount;
    }

    // -- Stop Loss User Facing Functions -- //
    function placeStopLoss(IPoolManager.PoolKey calldata poolKey, int24 tickLower, uint256 amountIn, bool zeroForOne)
        external
        returns (int24 tick)
    {
        // round down according to tickSpacing
        // TODO: should we round up depending on direction of the position?
        tick = getTickFloor(tickLower, poolKey.tickSpacing);
        // TODO: safe casting
        stopLossPositions[poolKey.toId()][tick][zeroForOne] += int256(amountIn);

        // mint the receipt token
        uint256 tokenId = getTokenId(poolKey, tick, zeroForOne);
        if (!tokenIdExists[tokenId]) {
            tokenIdExists[tokenId] = true;
            tokenIdIndex[tokenId] = TokenIdData({poolKey: poolKey, tickLower: tick, zeroForOne: zeroForOne});
        }
        _mint(msg.sender, tokenId, amountIn, "");
        totalSupply[tokenId] += amountIn;

        // interactions: transfer token0 to this contract
        address token = zeroForOne ? Currency.unwrap(poolKey.currency0) : Currency.unwrap(poolKey.currency1);
        IERC20(token).transferFrom(msg.sender, address(this), amountIn);
    }

    // TODO: implement, is out of scope for the hackathon
    function killStopLoss() external {}
    // ------------------------------------- //

    // -- 1155 -- //
    function uri(uint256) public pure override returns (string memory) {
        return "https://example.com";
    }

    function getTokenId(IPoolManager.PoolKey calldata poolKey, int24 tickLower, bool zeroForOne)
        public
        pure
        returns (uint256)
    {
        return uint256(keccak256(abi.encodePacked(poolKey.toId(), tickLower, zeroForOne)));
    }

    function redeem(uint256 tokenId, uint256 amountIn, address destination) external {
        // checks: an amount to redeem
        require(claimable[tokenId] > 0, "StopLoss: no claimable amount");
        uint256 receiptBalance = balanceOf[msg.sender][tokenId];
        require(amountIn <= receiptBalance, "StopLoss: not enough tokens to redeem");

        TokenIdData memory data = tokenIdIndex[tokenId];
        address token =
            data.zeroForOne ? Currency.unwrap(data.poolKey.currency1) : Currency.unwrap(data.poolKey.currency0);

        // effects: burn the token
        // amountOut = claimable * (amountIn / totalSupply)
        uint256 amountOut = amountIn.mulDivDown(claimable[tokenId], totalSupply[tokenId]);
        claimable[tokenId] -= amountOut;
        _burn(msg.sender, tokenId, amountIn);
        totalSupply[tokenId] -= amountIn;

        // interaction: transfer the underlying to the caller
        IERC20(token).transfer(destination, amountOut);
    }
    // ---------- //

    // -- Util functions -- //
    function setTickLowerLast(bytes32 poolId, int24 tickLower) private {
        tickLowerLasts[poolId] = tickLower;
    }

    function getTickFloor(int24 tick, int24 tickSpacing) private pure returns (int24) {
        int24 compressed = tick / tickSpacing;
        if (tick < 0 && tick % tickSpacing != 0) compressed--; // round towards negative infinity
        return compressed * tickSpacing;
    }

    function getTickCeil(int24 tick, int24 tickSpacing) private pure returns (int24) {
        int24 compressed = tick / tickSpacing;
        if (tick > 0 && tick % tickSpacing != 0) compressed++; // round towards positive infinity
        return compressed * tickSpacing;
    }

    function latestTwapTick(IPoolManager.PoolKey memory key) internal view returns (int24) {
        uint32[] memory secondsAgo = new uint32[](2);
        secondsAgo[0] = 60;
        secondsAgo[1] = 0;
        (int56[] memory tickCumulatives,) = oracleHook.observe(
            IPoolManager.PoolKey({
                currency0: key.currency0,
                currency1: key.currency1,
                fee: 0,
                tickSpacing: poolManager.MAX_TICK_SPACING(),
                hooks: IHooks(address(oracleHook))
            }),
            secondsAgo
        );
        int56 tickDiff = tickCumulatives[1] - tickCumulatives[0];
        return int24(tickDiff / 60);
    }
}
