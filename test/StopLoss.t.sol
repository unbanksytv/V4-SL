// SPDX-License-Identifier: MIT
pragma solidity ^0.8.15;

import "forge-std/Test.sol";
import {GasSnapshot} from "forge-gas-snapshot/GasSnapshot.sol";
import {TestERC20} from "@uniswap/v4-core/contracts/test/TestERC20.sol";
import {IERC20Minimal} from "@uniswap/v4-core/contracts/interfaces/external/IERC20Minimal.sol";
import {IHooks} from "@uniswap/v4-core/contracts/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/contracts/libraries/Hooks.sol";
import {TickMath} from "@uniswap/v4-core/contracts/libraries/TickMath.sol";
import {PoolManager} from "@uniswap/v4-core/contracts/PoolManager.sol";
import {IPoolManager} from "@uniswap/v4-core/contracts/interfaces/IPoolManager.sol";
import {PoolId} from "@uniswap/v4-core/contracts/libraries/PoolId.sol";
import {PoolModifyPositionTest} from "@uniswap/v4-core/contracts/test/PoolModifyPositionTest.sol";
import {PoolSwapTest} from "@uniswap/v4-core/contracts/test/PoolSwapTest.sol";
import {PoolDonateTest} from "@uniswap/v4-core/contracts/test/PoolDonateTest.sol";
import {Deployers} from "@uniswap/v4-core/test/foundry-tests/utils/Deployers.sol";
import {CurrencyLibrary, Currency} from "@uniswap/v4-core/contracts/libraries/CurrencyLibrary.sol";
import {StopLoss} from "../src/StopLoss.sol";
import {StopLossImplementation} from "../src/implementation/StopLossImplementation.sol";

contract StopLossTest is Test, Deployers, GasSnapshot {
    using PoolId for IPoolManager.PoolKey;
    using CurrencyLibrary for Currency;

    StopLoss hook = StopLoss(address(uint160(Hooks.AFTER_INITIALIZE_FLAG | Hooks.AFTER_SWAP_FLAG)));
    PoolManager manager;
    PoolModifyPositionTest modifyPositionRouter;
    PoolSwapTest swapRouter;
    TestERC20 _tokenA;
    TestERC20 _tokenB;
    TestERC20 token0;
    TestERC20 token1;
    IPoolManager.PoolKey poolKey;
    bytes32 poolId;

    function setUp() public {
        _tokenA = new TestERC20(2**128);
        _tokenB = new TestERC20(2**128);

        if (address(_tokenA) < address(_tokenB)) {
            token0 = _tokenA;
            token1 = _tokenB;
        } else {
            token0 = _tokenB;
            token1 = _tokenA;
        }

        manager = new PoolManager(500000);

        // testing environment requires our contract to override `validateHookAddress`
        // well do that via the Implementation contract to avoid deploying the override with the production contract
        StopLossImplementation impl = new StopLossImplementation(manager, hook);
        (, bytes32[] memory writes) = vm.accesses(address(impl));
        vm.etch(address(hook), address(impl).code);
        // for each storage key that was written during the hook implementation, copy the value over
        unchecked {
            for (uint256 i = 0; i < writes.length; i++) {
                bytes32 slot = writes[i];
                vm.store(address(hook), slot, vm.load(address(impl), slot));
            }
        }

        // Create the pool
        poolKey =
            IPoolManager.PoolKey(Currency.wrap(address(token0)), Currency.wrap(address(token1)), 3000, 60, IHooks(hook));
        poolId = PoolId.toId(poolKey);
        manager.initialize(poolKey, SQRT_RATIO_1_1);

        // Helpers for interacting with the pool
        modifyPositionRouter = new PoolModifyPositionTest(IPoolManager(address(manager)));
        swapRouter = new PoolSwapTest(IPoolManager(address(manager)));

        // Provide liquidity to the pool
        token0.approve(address(modifyPositionRouter), 100 ether);
        token1.approve(address(modifyPositionRouter), 100 ether);
        token0.mint(address(this), 100 ether);
        token1.mint(address(this), 100 ether);
        modifyPositionRouter.modifyPosition(poolKey, IPoolManager.ModifyPositionParams(-60, 60, 10 ether));
        modifyPositionRouter.modifyPosition(poolKey, IPoolManager.ModifyPositionParams(-120, 120, 10 ether));
        modifyPositionRouter.modifyPosition(
            poolKey, IPoolManager.ModifyPositionParams(TickMath.minUsableTick(60), TickMath.maxUsableTick(60), 50 ether)
        );

        // Approve for swapping
        token0.approve(address(swapRouter), 100 ether);
        token1.approve(address(swapRouter), 100 ether);
    }

    // Place/open a stop loss position
    function test_place() public {
        int24 tick = 100;
        uint256 amount = 100e18;
        bool zeroForOne = true;

        uint256 balanceBefore = token0.balanceOf(address(this));
        token0.approve(address(hook), amount);

        // place the stop loss position to sell 100 tokens at tick 0
        int24 actualTick = hook.placeStopLoss(poolKey, tick, amount, zeroForOne);
        assertEq(actualTick, 60); // tick spacing of 60 means we "round" tick 100 to 60
        uint256 balanceAfter = token0.balanceOf(address(this));
        assertEq(balanceBefore - balanceAfter, amount);

        int256 stopLossAmt = hook.stopLossPositions(poolKey.toId(), actualTick, zeroForOne);
        assertEq(stopLossAmt, int256(amount));

        // contract received a receipt token
        uint256 tokenId = hook.getTokenId(poolKey, actualTick, zeroForOne);
        assertEq(tokenId != 0, true);
        uint256 receiptBal = hook.balanceOf(address(this), tokenId);
        assertEq(receiptBal, amount);
    }

    // Stop loss execution happens when theres a trade in the opposite direction
    // of the position. To test execution, we have a zeroForOne stop loss when
    // the tick price is less than 100. The pool by default is initialized to tick
    // price 0. Therefore, assume the pool had enough trades to move the tick price
    // below 100. On the next oneForZero trade, the stop loss should be executed.
    function test_stopLossExecute_zeroForOne() public {
        int24 tick = 100;
        uint256 amount = 10e18;
        bool zeroForOne = true;

        token0.approve(address(hook), amount);
        int24 actualTick = hook.placeStopLoss(poolKey, tick, amount, zeroForOne);

        // Perform a test swap //
        // Swap in the opposite direction of the stop loss to trigger it
        // moves the tick from 0 to 300
        IPoolManager.SwapParams memory params = IPoolManager.SwapParams({
            zeroForOne: !zeroForOne,
            amountSpecified: 1e18,
            sqrtPriceLimitX96: TickMath.MAX_SQRT_RATIO - 1
        });

        PoolSwapTest.TestSettings memory testSettings =
            PoolSwapTest.TestSettings({withdrawTokens: true, settleUsingTransfer: true});

        swapRouter.swap(poolKey, params, testSettings);
        // ------------------- //

        // stoploss should be executed
        int256 stopLossAmt = hook.stopLossPositions(poolKey.toId(), tick, zeroForOne);
        assertEq(stopLossAmt, 0);

        // receipt tokens are redeemable for token1 (token0 was sold in the stop loss)
        uint256 tokenId = hook.getTokenId(poolKey, actualTick, zeroForOne);
        uint256 redeemable = hook.claimable(tokenId);
        assertEq(redeemable, token1.balanceOf(address(hook))); // we're the only holders so we can redeem it all

        // redeem all of the receipt for the underlying
        uint256 balanceBefore = token1.balanceOf(address(this));
        hook.redeem(tokenId, hook.balanceOf(address(this), tokenId), address(this));
        uint256 balanceAfter = token1.balanceOf(address(this));
        assertEq(balanceAfter - balanceBefore, redeemable);
        assertEq(token1.balanceOf(address(hook)), 0); // redeemed it all
    }

    // -- Allow the test contract to receive ERC1155 tokens -- //
    receive() external payable {}

    function onERC1155Received(address, address, uint256, uint256, bytes calldata) external pure returns (bytes4) {
        return bytes4(keccak256("onERC1155Received(address,address,uint256,uint256,bytes)"));
    }

    function onERC1155BatchReceived(address, address, uint256[] calldata, uint256[] calldata, bytes calldata)
        external
        pure
        returns (bytes4)
    {
        return bytes4(keccak256("onERC1155BatchReceived(address,address,uint256[],uint256[],bytes)"));
    }
}
