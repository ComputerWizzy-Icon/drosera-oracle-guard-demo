// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";

import {AMMOracle} from "../src/AMMOracle.sol";
import {DroseraResponder} from "../src/DroseraResponder.sol";
import {MockProductionLendingPool} from "../src/MockProductionLendingPool.sol";
import {OracleManipulationTrap} from "../src/OracleManipulationTrap.sol";
import {TestableOracleManipulationTrap} from "../src/TestableOracleManipulationTrap.sol";

contract AttackSimulation is Test {
    uint256 internal constant REASON_PRICE_SPIKE_AND_LIQUIDITY_DROP = 1;
    uint256 internal constant REASON_PRICE_CRASH_AND_LIQUIDITY_DROP = 2;
    uint256 internal constant REASON_READ_FAILURE_ALERT_ONLY = 3;
    uint256 internal constant REASON_STALE_ORACLE_ALERT_ONLY = 4;

    AMMOracle internal oracle;
    MockProductionLendingPool internal pool;
    OracleManipulationTrap internal trap;
    DroseraResponder internal responder;

    address internal owner = address(1);
    address internal relayer = address(999);
    address internal attacker = address(666);

    bytes[] internal buffer;

    struct CollectOutput {
        uint256 schemaVersion;
        address pool;
        address oracle;
        uint256 price;
        uint256 oracleUpdatedAt;
        uint256 availableLiquidity;
        uint256 totalBorrows;
        uint256 totalCollateral;
        uint256 totalBadDebt;
        uint256 utilizationBps;
        uint256 totalAssets;
        uint256 paused;
        uint256 blockNumber;
        uint256 blockTimestamp;
        uint256 oracleReadOk;
        uint256 metricsReadOk;
        uint256 pausedReadOk;
    }

    function setUp() public {
        vm.chainId(560048);

        vm.startPrank(owner);

        oracle = new AMMOracle(1000 ether, 1000 ether);
        pool = new MockProductionLendingPool(owner, address(oracle));
        responder = new DroseraResponder(owner, relayer, 20);

        responder.setApprovedPool(address(pool), true);
        pool.setResponder(address(responder));

        vm.deal(owner, 200 ether);
        pool.fundLiquidity{value: 100 ether}();

        vm.stopPrank();

        trap = new OracleManipulationTrap();

        vm.deal(attacker, 50 ether);
        buffer = new bytes[](5);
    }

    function _sample(
        uint256 price,
        uint256 oracleUpdatedAt,
        uint256 availableLiquidity,
        uint256 blk,
        uint256 ts
    ) internal view returns (bytes memory) {
        (
            ,
            uint256 totalBorrowed,
            uint256 totalCollat,
            uint256 badDebt,
            uint256 utilizationBps,
            uint256 totalAssets
        ) = pool.getRiskMetrics();

        return
            abi.encode(
                CollectOutput({
                    schemaVersion: 1,
                    pool: address(pool),
                    oracle: address(oracle),
                    price: price,
                    oracleUpdatedAt: oracleUpdatedAt,
                    availableLiquidity: availableLiquidity,
                    totalBorrows: totalBorrowed,
                    totalCollateral: totalCollat,
                    totalBadDebt: badDebt,
                    utilizationBps: utilizationBps,
                    totalAssets: totalAssets,
                    paused: pool.paused() ? 1 : 0,
                    blockNumber: blk,
                    blockTimestamp: ts,
                    oracleReadOk: 1,
                    metricsReadOk: 1,
                    pausedReadOk: 1
                })
            );
    }

    function test_collect_reads_real_oracle_and_pool() public {
        TestableOracleManipulationTrap testTrap = new TestableOracleManipulationTrap(
                address(oracle),
                address(pool)
            );

        vm.roll(123);
        vm.warp(1_000_000);

        bytes memory raw = testTrap.collect();
        CollectOutput memory out = abi.decode(raw, (CollectOutput));

        assertEq(out.schemaVersion, 1);
        assertEq(out.pool, address(pool));
        assertEq(out.oracle, address(oracle));
        assertEq(out.price, 1e18);
        assertEq(out.availableLiquidity, 100 ether);
        assertEq(out.totalBorrows, 0);
        assertEq(out.totalCollateral, 0);
        assertEq(out.totalBadDebt, 0);
        assertEq(out.utilizationBps, 0);
        assertEq(out.totalAssets, 100 ether);
        assertEq(out.paused, 0);
        assertEq(out.blockNumber, 123);
        assertEq(out.blockTimestamp, 1_000_000);
        assertEq(out.oracleReadOk, 1);
        assertEq(out.metricsReadOk, 1);
        assertEq(out.pausedReadOk, 1);
        assertGt(out.oracleUpdatedAt, 0);
    }

    function test_spike_and_liquidity_drop_triggers_trap() public {
        uint256 basePrice = 1e18;
        uint256 baseLiquidity = 100 ether;
        uint256 ts = block.timestamp;

        buffer[4] = _sample(basePrice, ts, baseLiquidity, 100, ts);
        buffer[3] = _sample(basePrice, ts, baseLiquidity, 101, ts + 12);
        buffer[2] = _sample(basePrice, ts, baseLiquidity, 102, ts + 24);
        buffer[1] = _sample(basePrice, ts, baseLiquidity, 103, ts + 36);

        vm.roll(104);
        vm.warp(ts + 48);

        vm.startPrank(attacker);
        oracle.swap1For0(4000 ether);
        pool.depositCollateral{value: 5 ether}();
        pool.borrow(50 ether);
        vm.stopPrank();

        (uint256 attackPrice, uint256 updatedAt) = oracle.getLatestPrice();
        (uint256 attackLiquidity, , , , , ) = pool.getRiskMetrics();

        buffer[0] = _sample(
            attackPrice,
            updatedAt,
            attackLiquidity,
            104,
            block.timestamp
        );

        assertTrue(attackPrice >= basePrice * 5, "price spike expected");
        assertTrue(
            attackLiquidity < (baseLiquidity * 9) / 10,
            "liquidity drop expected"
        );

        (bool trigger, bytes memory payload) = trap.shouldRespond(buffer);
        assertTrue(trigger, "trap should fire");

        OracleManipulationTrap.ResponsePayload memory resp = abi.decode(
            payload,
            (OracleManipulationTrap.ResponsePayload)
        );

        assertEq(resp.pool, address(pool));
        assertEq(resp.reason, REASON_PRICE_SPIKE_AND_LIQUIDITY_DROP);

        vm.prank(relayer);
        responder.executeResponse(payload);

        assertTrue(pool.paused(), "pool should be paused");
        assertEq(responder.responseCount(), 1);

        vm.prank(relayer);
        responder.executeResponse(payload);

        assertTrue(pool.paused(), "idempotent pause");
        assertEq(responder.responseCount(), 1);
    }

    function test_malformed_data_does_not_revert() public view {
        bytes[] memory malformed = new bytes[](5);

        malformed[0] = hex"1234";
        malformed[1] = hex"";
        malformed[2] = hex"abcdef";
        malformed[3] = hex"01";
        malformed[4] = hex"02";

        (bool trigger, bytes memory payload) = trap.shouldRespond(malformed);

        assertFalse(trigger);
        assertEq(payload.length, 0);
    }

    function test_should_alert_on_stale_oracle() public {
        bytes[] memory samples = new bytes[](1);
        uint256 price = 1e18;
        uint256 staleUpdatedAt = 1;
        uint256 liquidity = 100 ether;
        uint256 staleSampleTime = staleUpdatedAt + 1 hours + 1;

        samples[0] = _sample(
            price,
            staleUpdatedAt,
            liquidity,
            100,
            staleSampleTime
        );

        (bool alerting, bytes memory payload) = trap.shouldAlert(samples);
        assertTrue(alerting);

        OracleManipulationTrap.ResponsePayload memory resp = abi.decode(
            payload,
            (OracleManipulationTrap.ResponsePayload)
        );

        assertEq(resp.reason, REASON_STALE_ORACLE_ALERT_ONLY);
        assertEq(resp.currentLiquidity, liquidity);
    }

    function test_should_alert_on_read_failure() public {
        bytes[] memory samples = new bytes[](1);

        samples[0] = abi.encode(
            CollectOutput({
                schemaVersion: 1,
                pool: address(pool),
                oracle: address(oracle),
                price: 0,
                oracleUpdatedAt: 0,
                availableLiquidity: 0,
                totalBorrows: 0,
                totalCollateral: 0,
                totalBadDebt: 0,
                utilizationBps: 0,
                totalAssets: 0,
                paused: 0,
                blockNumber: 100,
                blockTimestamp: 200,
                oracleReadOk: 0,
                metricsReadOk: 1,
                pausedReadOk: 1
            })
        );

        (bool alerting, bytes memory payload) = trap.shouldAlert(samples);
        assertTrue(alerting);

        OracleManipulationTrap.ResponsePayload memory resp = abi.decode(
            payload,
            (OracleManipulationTrap.ResponsePayload)
        );

        assertEq(resp.reason, REASON_READ_FAILURE_ALERT_ONLY);
    }

    function test_response_wrong_relayer_fails_correct_relayer_succeeds()
        public
    {
        uint256 basePrice = 1e18;
        uint256 baseLiquidity = 100 ether;
        uint256 ts = block.timestamp;

        buffer[4] = _sample(basePrice, ts, baseLiquidity, 100, ts);
        buffer[3] = _sample(basePrice, ts, baseLiquidity, 101, ts + 12);
        buffer[2] = _sample(basePrice, ts, baseLiquidity, 102, ts + 24);
        buffer[1] = _sample(basePrice, ts, baseLiquidity, 103, ts + 36);

        vm.roll(104);
        vm.warp(ts + 48);

        vm.startPrank(attacker);
        oracle.swap1For0(4000 ether);
        pool.depositCollateral{value: 5 ether}();
        pool.borrow(50 ether);
        vm.stopPrank();

        (uint256 attackPrice, uint256 updatedAt) = oracle.getLatestPrice();
        (uint256 attackLiquidity, , , , , ) = pool.getRiskMetrics();

        buffer[0] = _sample(
            attackPrice,
            updatedAt,
            attackLiquidity,
            104,
            block.timestamp
        );

        (bool trigger, bytes memory payload) = trap.shouldRespond(buffer);
        assertTrue(trigger, "trap should fire");

        address wrongRelayer = address(12345);

        vm.prank(wrongRelayer);
        vm.expectRevert(DroseraResponder.NotRelayer.selector);
        responder.executeResponse(payload);

        assertFalse(pool.paused(), "pool should not pause from wrong relayer");

        vm.prank(relayer);
        responder.executeResponse(payload);

        assertTrue(pool.paused(), "pool should pause from correct relayer");
    }

    function test_no_false_positive_on_normal_operation() public {
        uint256 price = 1e18;
        uint256 liquidity = 100 ether;
        uint256 ts = block.timestamp;

        for (uint256 i = 0; i < 5; i++) {
            buffer[4 - i] = _sample(
                price,
                ts + (i * 12),
                liquidity,
                100 + i,
                ts + (i * 12)
            );
        }

        vm.roll(105);

        (bool trigger, ) = trap.shouldRespond(buffer);

        assertFalse(trigger);
    }

    function test_price_spike_without_liquidity_drop_should_not_trigger()
        public
    {
        uint256 price = 1e18;
        uint256 liquidity = 100 ether;
        uint256 ts = block.timestamp;

        buffer[4] = _sample(price, ts, liquidity, 100, ts);
        buffer[3] = _sample(price, ts, liquidity, 101, ts + 12);
        buffer[2] = _sample(price, ts, liquidity, 102, ts + 24);
        buffer[1] = _sample(price, ts, liquidity, 103, ts + 36);

        vm.roll(104);
        vm.warp(ts + 48);

        oracle.swap1For0(500 ether);

        (uint256 manipulatedPrice, uint256 updatedAt) = oracle.getLatestPrice();
        buffer[0] = _sample(
            manipulatedPrice,
            updatedAt,
            liquidity,
            104,
            block.timestamp
        );

        (bool trigger, ) = trap.shouldRespond(buffer);

        assertFalse(trigger);
    }

    function test_full_drain_caught() public {
        uint256 basePrice = 1e18;
        uint256 baseLiquidity = 100 ether;
        uint256 ts = block.timestamp;

        buffer[4] = _sample(basePrice, ts, baseLiquidity, 100, ts);
        buffer[3] = _sample(basePrice, ts, baseLiquidity, 101, ts + 12);
        buffer[2] = _sample(basePrice, ts, baseLiquidity, 102, ts + 24);
        buffer[1] = _sample(basePrice, ts, baseLiquidity, 103, ts + 36);

        vm.roll(104);
        vm.warp(ts + 48);

        oracle.swap0For1(9000 ether);

        (uint256 crashPrice, uint256 updatedAt) = oracle.getLatestPrice();
        buffer[0] = _sample(crashPrice, updatedAt, 0, 104, block.timestamp);

        (bool trigger, bytes memory payload) = trap.shouldRespond(buffer);
        assertTrue(trigger);

        OracleManipulationTrap.ResponsePayload memory resp = abi.decode(
            payload,
            (OracleManipulationTrap.ResponsePayload)
        );

        assertEq(resp.reason, REASON_PRICE_CRASH_AND_LIQUIDITY_DROP);
        assertEq(resp.currentLiquidity, 0);
    }

    function test_liquidity_drop_alone_should_not_trigger() public {
        uint256 price = 1e18;
        uint256 liquidity = 100 ether;
        uint256 ts = block.timestamp;

        buffer[4] = _sample(price, ts, liquidity, 100, ts);
        buffer[3] = _sample(price, ts, liquidity, 101, ts + 12);
        buffer[2] = _sample(price, ts, liquidity, 102, ts + 24);
        buffer[1] = _sample(price, ts, liquidity, 103, ts + 36);

        vm.roll(104);
        vm.warp(ts + 48);

        buffer[0] = _sample(price, ts + 48, 85 ether, 104, block.timestamp);

        (bool trigger, ) = trap.shouldRespond(buffer);

        assertFalse(trigger);
    }

    function test_responder_cooldown_blocks_second_incident() public {
        OracleManipulationTrap.ResponsePayload
            memory payloadOne = OracleManipulationTrap.ResponsePayload({
                pool: address(pool),
                reason: REASON_PRICE_SPIKE_AND_LIQUIDITY_DROP,
                currentPrice: 5e18,
                baselinePrice: 1e18,
                currentLiquidity: 40 ether,
                baselineLiquidity: 100 ether,
                currentBlockNumber: block.number
            });

        OracleManipulationTrap.ResponsePayload
            memory payloadTwo = OracleManipulationTrap.ResponsePayload({
                pool: address(pool),
                reason: REASON_PRICE_CRASH_AND_LIQUIDITY_DROP,
                currentPrice: 1e17,
                baselinePrice: 1e18,
                currentLiquidity: 30 ether,
                baselineLiquidity: 100 ether,
                currentBlockNumber: block.number + 1
            });

        vm.prank(relayer);
        responder.executeResponse(abi.encode(payloadOne));

        assertTrue(pool.paused());

        vm.prank(owner);
        pool.emergencyUnpause();

        vm.roll(block.number + 1);
        vm.prank(relayer);
        vm.expectRevert(DroseraResponder.CooldownActive.selector);
        responder.executeResponse(abi.encode(payloadTwo));
    }
}
