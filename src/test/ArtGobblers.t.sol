// SPDX-License-Identifier: MIT
pragma solidity >=0.8.0;

import {DSTestPlus} from "solmate/test/utils/DSTestPlus.sol";
import {ERC1155TokenReceiver} from "solmate/tokens/ERC1155.sol";
import {Utilities} from "./utils/Utilities.sol";
import {console} from "./utils/Console.sol";
import {Vm} from "forge-std/Vm.sol";
import {stdError} from "forge-std/Test.sol";
import {ArtGobblers} from "../ArtGobblers.sol";
import {Goo} from "../Goo.sol";
import {Pages} from "../Pages.sol";
import {GobblerReserve} from "../utils/GobblerReserve.sol";
import {LinkToken} from "./utils/mocks/LinkToken.sol";
import {VRFCoordinatorMock} from "chainlink/v0.8/mocks/VRFCoordinatorMock.sol";
import {ERC721} from "solmate/tokens/ERC721.sol";
import {MockERC1155} from "solmate/test/utils/mocks/MockERC1155.sol";
import {LibString} from "../utils/LibString.sol";

/// @notice Unit test for Art Gobbler Contract.
contract ArtGobblersTest is DSTestPlus, ERC1155TokenReceiver {
    using LibString for uint256;

    Vm internal immutable vm = Vm(HEVM_ADDRESS);

    Utilities internal utils;
    address payable[] internal users;

    ArtGobblers internal gobblers;
    VRFCoordinatorMock internal vrfCoordinator;
    LinkToken internal linkToken;
    Goo internal goo;
    Pages internal pages;
    GobblerReserve internal team;
    GobblerReserve internal community;

    bytes32 private keyHash;
    uint256 private fee;

    uint256[] ids;

    /*//////////////////////////////////////////////////////////////
                                  SETUP
    //////////////////////////////////////////////////////////////*/

    function setUp() public {
        utils = new Utilities();
        users = utils.createUsers(5);
        linkToken = new LinkToken();
        vrfCoordinator = new VRFCoordinatorMock(address(linkToken));

        team = new GobblerReserve(ArtGobblers(utils.predictContractAddress(address(this), 3)), address(this));
        community = new GobblerReserve(ArtGobblers(utils.predictContractAddress(address(this), 2)), address(this));

        goo = new Goo(
            // Gobblers:
            utils.predictContractAddress(address(this), 1),
            // Pages:
            utils.predictContractAddress(address(this), 2)
        );

        gobblers = new ArtGobblers(
            keccak256(abi.encodePacked(users[0])),
            block.timestamp,
            goo,
            address(team),
            address(community),
            address(vrfCoordinator),
            address(linkToken),
            keyHash,
            fee,
            "base",
            ""
        );

        pages = new Pages(block.timestamp, goo, address(0xBEEF), address(gobblers), "");
    }

    /*//////////////////////////////////////////////////////////////
                               MINT TESTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Test that minting from the mintlist before minting starts fails.
    function testMintFromMintlistBeforeMintingStarts() public {
        vm.warp(block.timestamp - 1);

        address user = users[0];
        bytes32[] memory proof;
        vm.prank(user);
        vm.expectRevert(ArtGobblers.MintStartPending.selector);
        gobblers.claimGobbler(proof);
    }

    /// @notice Test that you can mint from mintlist successfully.
    function testMintFromMintlist() public {
        address user = users[0];
        bytes32[] memory proof;
        vm.prank(user);
        gobblers.claimGobbler(proof);
        // verify gobbler ownership
        assertEq(gobblers.ownerOf(1), user);
    }

    /// @notice Test that minting from the mintlist twice fails.
    function testMintingFromMintlistTwiceFails() public {
        address user = users[0];
        bytes32[] memory proof;
        vm.startPrank(user);
        gobblers.claimGobbler(proof);

        vm.expectRevert(ArtGobblers.AlreadyClaimed.selector);
        gobblers.claimGobbler(proof);
    }

    /// @notice Test that an invalid mintlist proof reverts.
    function testMintNotInMintlist() public {
        bytes32[] memory proof;
        vm.expectRevert(ArtGobblers.InvalidProof.selector);
        gobblers.claimGobbler(proof);
    }

    /// @notice Test that you can successfully mint from goo.
    function testMintFromGoo() public {
        uint256 cost = gobblers.gobblerPrice();
        vm.prank(address(gobblers));
        goo.mintForGobblers(users[0], cost);
        vm.prank(users[0]);
        gobblers.mintFromGoo(type(uint256).max);
        assertEq(gobblers.ownerOf(1), users[0]);
    }

    /// @notice Test that trying to mint with insufficient balance reverts.
    function testMintInsufficientBalance() public {
        vm.prank(users[0]);
        vm.expectRevert(stdError.arithmeticError);
        gobblers.mintFromGoo(type(uint256).max);
    }

    /// @notice Test that if mint price exceeds max it reverts.
    function testMintPriceExceededMax() public {
        uint256 cost = gobblers.gobblerPrice();
        vm.prank(address(gobblers));
        goo.mintForGobblers(users[0], cost);
        vm.prank(users[0]);
        vm.expectRevert(abi.encodeWithSelector(ArtGobblers.PriceExceededMax.selector, cost));
        gobblers.mintFromGoo(cost - 1);
    }

    /// @notice Test that initial gobbler price is what we expect.
    function testInitialGobblerPrice() public {
        uint256 cost = gobblers.gobblerPrice();
        uint256 maxDelta = 0.000000000000000070e18;
        assertApproxEq(cost, uint256(gobblers.initialPrice()), maxDelta);
    }

    /// @notice Test that minting reserved gobblers fails if there are no mints.
    function testMintReservedGobblersFailsWithNoMints() public {
        vm.expectRevert(ArtGobblers.ReserveImbalance.selector);
        gobblers.mintReservedGobblers(1);
    }

    /// @notice Test that reserved gobblers can be minted under fair circumstances.
    function testCanMintReserved() public {
        mintGobblerToAddress(users[0], 8);

        gobblers.mintReservedGobblers(1);
        assertEq(gobblers.ownerOf(9), address(team));
        assertEq(gobblers.ownerOf(10), address(community));
    }

    /// @notice Test multiple reserved gobblers can be minted under fair circumstances.
    function testCanMintMultipleReserved() public {
        mintGobblerToAddress(users[0], 18);

        gobblers.mintReservedGobblers(2);
        assertEq(gobblers.ownerOf(19), address(team));
        assertEq(gobblers.ownerOf(20), address(team));
        assertEq(gobblers.ownerOf(21), address(community));
        assertEq(gobblers.ownerOf(22), address(community));
    }

    /// @notice Test minting reserved gobblers fails if not enough have gobblers been minted.
    function testCantMintTooFastReserved() public {
        mintGobblerToAddress(users[0], 18);

        vm.expectRevert(ArtGobblers.ReserveImbalance.selector);
        gobblers.mintReservedGobblers(3);
    }

    /// @notice Test minting reserved gobblers fails one by one if not enough have gobblers been minted.
    function testCantMintTooFastReservedOneByOne() public {
        mintGobblerToAddress(users[0], 90);

        gobblers.mintReservedGobblers(1);
        gobblers.mintReservedGobblers(1);
        gobblers.mintReservedGobblers(1);
        gobblers.mintReservedGobblers(1);
        gobblers.mintReservedGobblers(1);
        gobblers.mintReservedGobblers(1);
        gobblers.mintReservedGobblers(1);
        gobblers.mintReservedGobblers(1);
        gobblers.mintReservedGobblers(1);
        gobblers.mintReservedGobblers(1);
        gobblers.mintReservedGobblers(1);

        vm.expectRevert(ArtGobblers.ReserveImbalance.selector);
        gobblers.mintReservedGobblers(1);
    }

    /*//////////////////////////////////////////////////////////////
                              PRICING TESTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Test VRGDA behavior when selling at target rate.
    function testPricingBasic() public {
        // VRGDA targets this number of mints at given time.
        uint256 timeDelta = 120 days;
        uint256 numMint = 877;

        vm.warp(block.timestamp + timeDelta);

        for (uint256 i = 0; i < numMint; i++) {
            vm.startPrank(address(gobblers));
            uint256 price = gobblers.gobblerPrice();
            goo.mintForGobblers(users[0], price);
            vm.stopPrank();
            vm.prank(users[0]);
            gobblers.mintFromGoo(price);
        }

        uint256 initialPrice = uint256(gobblers.initialPrice());
        uint256 finalPrice = gobblers.gobblerPrice();

        // Equal within 3 percent since num mint is rounded from true decimal amount.
        assertRelApproxEq(initialPrice, finalPrice, 0.03e18);
    }

    /*//////////////////////////////////////////////////////////////
                           LEGENDARY GOBBLERS
    //////////////////////////////////////////////////////////////*/

    /// @notice Test that attempting to mint before start time reverts.
    function testLegendaryGobblerMintBeforeStart() public {
        vm.expectRevert(stdError.arithmeticError);
        vm.prank(users[0]);
        gobblers.mintLegendaryGobbler(ids);
    }

    /// @notice Test that Legendary Gobbler initial price is what we expect.
    function testLegendaryGobblerInitialPrice() public {
        // Start of initial auction after initial interval is minted.
        mintGobblerToAddress(users[0], gobblers.LEGENDARY_AUCTION_INTERVAL());
        uint256 cost = gobblers.legendaryGobblerPrice();
        // Initial auction should start at a cost of 69.
        assertEq(cost, 69);
    }

    /// @notice Test that auction ends at a price of 0.
    function testLegendaryGobblerFinalPrice() public {
        // Mint 2 full intervals.
        mintGobblerToAddress(users[0], gobblers.LEGENDARY_AUCTION_INTERVAL() * 2);
        uint256 cost = gobblers.legendaryGobblerPrice();
        // Auction price should be 0 after full interval decay.
        assertEq(cost, 0);
    }

    /// @notice Test that auction ends at a price of 0 even after the interval.
    function testLegendaryGobblerPastFinalPrice() public {
        // Mint 3 full intervals.
        vm.warp(block.timestamp + 600 days);
        mintGobblerToAddress(users[0], gobblers.LEGENDARY_AUCTION_INTERVAL() * 3);
        uint256 cost = gobblers.legendaryGobblerPrice();
        // Auction price should be 0 after full interval decay.
        assertEq(cost, 0);
    }

    /// @notice Test that mid price happens when we expect.
    function testLegendaryGobblerMidPrice() public {
        // Mint first interval and half of second interval.
        mintGobblerToAddress(users[0], (gobblers.LEGENDARY_AUCTION_INTERVAL() * 3) / 2);
        uint256 cost = gobblers.legendaryGobblerPrice();
        // Auction price should be cut by half mid way through auction.
        assertEq(cost, 34);
    }

    /// @notice Test that initial price does't fall below what we expect.
    function testLegendaryGobblerMinStartPrice() public {
        // Mint two full intervals, such that price of first auction goes to zero.
        mintGobblerToAddress(users[0], gobblers.LEGENDARY_AUCTION_INTERVAL() * 2);
        // Empty id list.
        uint256[] memory _ids;
        // Mint first auction at zero cost.
        gobblers.mintLegendaryGobbler(_ids);
        // Start cost of next auction, which should equal 69.
        uint256 startCost = gobblers.legendaryGobblerPrice();
        assertEq(startCost, 69);
    }

    /// @notice Test that Legendary Gobblers can be minted.
    function testMintLegendaryGobbler() public {
        uint256 startTime = block.timestamp + 30 days;
        vm.warp(startTime);
        // Mint full interval to kick off first auction.
        mintGobblerToAddress(users[0], gobblers.LEGENDARY_AUCTION_INTERVAL());
        uint256 cost = gobblers.legendaryGobblerPrice();
        assertEq(cost, 69);
        setRandomnessAndReveal(cost, "seed");
        uint256 emissionMultipleSum;
        for (uint256 curId = 1; curId <= cost; curId++) {
            ids.push(curId);
            assertEq(gobblers.ownerOf(curId), users[0]);
            emissionMultipleSum += gobblers.getGobblerEmissionMultiple(curId);
        }

        assertEq(gobblers.getUserEmissionMultiple(users[0]), emissionMultipleSum);

        vm.prank(users[0]);
        uint256 mintedLegendaryId = gobblers.mintLegendaryGobbler(ids);

        // Legendary is owned by user.
        assertEq(gobblers.ownerOf(mintedLegendaryId), users[0]);
        assertEq(gobblers.getUserEmissionMultiple(users[0]), emissionMultipleSum * 2);

        assertEq(gobblers.getGobblerEmissionMultiple(mintedLegendaryId), emissionMultipleSum * 2);

        for (uint256 i = 0; i < ids.length; i++) assertEq(gobblers.ownerOf(ids[i]), address(0));
    }

    /// @notice Test that Legendary Gobblers can be minted at 0 cost.
    function testMintFreeLegendaryGobbler() public {
        uint256 startTime = block.timestamp + 30 days;
        vm.warp(startTime);

        // Mint 2 full intervals to send price to zero.
        mintGobblerToAddress(users[0], gobblers.LEGENDARY_AUCTION_INTERVAL() * 2);

        uint256 cost = gobblers.legendaryGobblerPrice();
        assertEq(cost, 0);

        vm.prank(users[0]);
        uint256 mintedLegendaryId = gobblers.mintLegendaryGobbler(ids);

        assertEq(gobblers.ownerOf(mintedLegendaryId), users[0]);
        assertEq(gobblers.getGobblerEmissionMultiple(mintedLegendaryId), 0);
    }

    /// @notice Test that Legendary Gobblers can be minted at 0 cost.
    function testMintFreeLegendaryGobblerPastInterval() public {
        uint256 startTime = block.timestamp + 30 days;
        vm.warp(startTime);

        // Mint 3 full intervals to send price to zero.
        mintGobblerToAddress(users[0], gobblers.LEGENDARY_AUCTION_INTERVAL() * 3);

        uint256 cost = gobblers.legendaryGobblerPrice();
        assertEq(cost, 0);

        vm.prank(users[0]);
        uint256 mintedLegendaryId = gobblers.mintLegendaryGobbler(ids);

        assertEq(gobblers.ownerOf(mintedLegendaryId), users[0]);
        assertEq(gobblers.getGobblerEmissionMultiple(mintedLegendaryId), 0);
    }

    /// @notice Test that legendary gobblers can't be minted with the wrong ids length.
    function testMintLegendaryGobblerWithWrongLength() public {
        uint256 startTime = block.timestamp + 30 days;
        vm.warp(startTime);
        // Mint full interval to kick off first auction.
        mintGobblerToAddress(users[0], gobblers.LEGENDARY_AUCTION_INTERVAL());
        uint256 cost = gobblers.legendaryGobblerPrice();
        assertEq(cost, 69);
        setRandomnessAndReveal(cost, "seed");
        uint256 emissionMultipleSum;
        for (uint256 curId = 1; curId <= cost; curId++) {
            ids.push(curId);
            assertEq(gobblers.ownerOf(curId), users[0]);
            emissionMultipleSum += gobblers.getGobblerEmissionMultiple(curId);
        }

        assertEq(gobblers.getUserEmissionMultiple(users[0]), emissionMultipleSum);

        ids.push(9999999);

        vm.prank(users[0]);
        vm.expectRevert(abi.encodeWithSelector(ArtGobblers.IncorrectGobblerAmount.selector, cost));
        gobblers.mintLegendaryGobbler(ids);
    }

    /// @notice Test that legendary gobblers can't be minted if the user doesn't own one of the ids.
    function testMintLegendaryGobblerWithUnownedId() public {
        uint256 startTime = block.timestamp + 30 days;
        vm.warp(startTime);
        // Mint full interval to kick off first auction.
        mintGobblerToAddress(users[0], gobblers.LEGENDARY_AUCTION_INTERVAL());
        uint256 cost = gobblers.legendaryGobblerPrice();
        assertEq(cost, 69);
        setRandomnessAndReveal(cost, "seed");
        uint256 emissionMultipleSum;
        for (uint256 curId = 1; curId <= cost; curId++) {
            ids.push(curId);
            assertEq(gobblers.ownerOf(curId), users[0]);
            emissionMultipleSum += gobblers.getGobblerEmissionMultiple(curId);
        }

        assertEq(gobblers.getUserEmissionMultiple(users[0]), emissionMultipleSum);

        ids.pop();
        ids.push(999);

        vm.prank(users[0]);
        vm.expectRevert("WRONG_FROM");
        gobblers.mintLegendaryGobbler(ids);
    }

    /// @notice Test that legendary gobblers have expected ids.
    function testMintLegendaryGobblersExpectedIds() public {
        // We expect the first legendary to have this id.
        uint256 nextMintLegendaryId = 9991;
        mintGobblerToAddress(users[0], gobblers.LEGENDARY_AUCTION_INTERVAL());
        for (int256 i = 0; i < 10; i++) {
            vm.warp(block.timestamp + 400 days);

            mintGobblerToAddress(users[0], gobblers.LEGENDARY_AUCTION_INTERVAL());
            uint256 justMintedLegendaryId = gobblers.mintLegendaryGobbler(ids);
            //assert that legendaries have the expected ids
            assertEq(nextMintLegendaryId, justMintedLegendaryId);
            nextMintLegendaryId++;
        }

        // Minting any more should fail.
        vm.expectRevert(ArtGobblers.NoRemainingLegendaryGobblers.selector);
        gobblers.mintLegendaryGobbler(ids);
    }

    /// @notice Test that Legendary Gobblers can't be burned to mint another legendary.
    function testCannotMintLegendaryWithLegendary() public {
        vm.warp(block.timestamp + 30 days);

        mintNextLegendary(users[0]);
        uint256 mintedLegendaryId = gobblers.FIRST_LEGENDARY_GOBBLER_ID();
        //First legendary to be minted should be 9991
        assertEq(mintedLegendaryId, 9991);
        uint256 cost = gobblers.legendaryGobblerPrice();

        // Starting price should be 69.
        assertEq(cost, 69);
        setRandomnessAndReveal(cost, "seed");
        for (uint256 i = 1; i <= cost; i++) ids.push(i);

        ids[0] = mintedLegendaryId; // Try to pass in the legendary we just minted as well.
        vm.prank(users[0]);
        vm.expectRevert(abi.encodeWithSelector(ArtGobblers.CannotBurnLegendary.selector, mintedLegendaryId));
        gobblers.mintLegendaryGobbler(ids);
    }

    /*//////////////////////////////////////////////////////////////
                                  URIS
    //////////////////////////////////////////////////////////////*/

    /// @notice Test unminted URI is correct.
    function testUnmintedUri() public {
        assertEq(gobblers.uri(1), "");
    }

    /// @notice Test that unrevealed URI is correct.
    function testUnrevealedUri() public {
        uint256 gobblerCost = gobblers.gobblerPrice();
        vm.prank(address(gobblers));
        goo.mintForGobblers(users[0], gobblerCost);
        vm.prank(users[0]);
        gobblers.mintFromGoo(type(uint256).max);
        // assert gobbler not revealed after mint
        assertTrue(stringEquals(gobblers.uri(1), gobblers.UNREVEALED_URI()));
    }

    /// @notice Test that revealed URI is correct.
    function testRevealedUri() public {
        mintGobblerToAddress(users[0], 1);
        // unrevealed gobblers have 0 value attributes
        assertEq(gobblers.getGobblerEmissionMultiple(1), 0);
        vm.warp(block.timestamp + 1 days);
        setRandomnessAndReveal(1, "seed");
        (, uint48 expectedIndex, ) = gobblers.getGobblerData(1);
        string memory expectedURI = string(abi.encodePacked(gobblers.BASE_URI(), uint256(expectedIndex).toString()));
        assertTrue(stringEquals(gobblers.uri(1), expectedURI));
    }

    /// @notice Test that legendary gobbler URI is correct.
    function testMintedLegendaryURI() public {
        //mint legendary for free
        mintGobblerToAddress(users[0], gobblers.LEGENDARY_AUCTION_INTERVAL() * 2);
        uint256 currentLegendaryId = gobblers.mintLegendaryGobbler(ids);

        //expected URI should not be shuffled
        string memory expectedURI = string(
            abi.encodePacked(gobblers.BASE_URI(), uint256(currentLegendaryId).toString())
        );
        string memory actualURI = gobblers.uri(currentLegendaryId);
        assertTrue(stringEquals(actualURI, expectedURI));
    }

    /// @notice Test that un-minted legendary gobbler URI is correct.
    function testUnmintedLegendaryUri() public {
        (, uint128 numSold) = gobblers.legendaryGobblerAuctionData();

        assertEq(gobblers.uri(gobblers.FIRST_LEGENDARY_GOBBLER_ID()), "");
        assertEq(gobblers.uri(gobblers.FIRST_LEGENDARY_GOBBLER_ID() + 1), "");
    }

    /*//////////////////////////////////////////////////////////////
                                 REVEALS
    //////////////////////////////////////////////////////////////*/

    function testDoesNotAllowRevealingZero() public {
        vm.warp(block.timestamp + 24 hours);
        vm.expectRevert(ArtGobblers.ZeroToBeRevealed.selector);
        gobblers.requestRandomSeed();
    }

    /// @notice Cannot request random seed before 24 hours have passed from initial mint.
    function testRevealDelayInitialMint() public {
        mintGobblerToAddress(users[0], 1);
        vm.expectRevert(ArtGobblers.RequestTooEarly.selector);
        gobblers.requestRandomSeed();
    }

    /// @notice Cannot reveal more gobblers than remaining to be revealed.
    function testCannotRevealMoreGobblersThanRemainingToBeRevealed() public {
        mintGobblerToAddress(users[0], 1);

        vm.warp(block.timestamp + 24 hours);

        bytes32 requestId = gobblers.requestRandomSeed();
        uint256 randomness = uint256(keccak256(abi.encodePacked("seed")));
        vrfCoordinator.callBackWithRandomness(requestId, randomness, address(gobblers));

        mintGobblerToAddress(users[0], 2);

        vm.expectRevert(abi.encodeWithSelector(ArtGobblers.NotEnoughRemainingToBeRevealed.selector, 1));
        gobblers.revealGobblers(2);
    }

    /// @notice Cannot request random seed before 24 hours have passed from last reveal,
    function testRevealDelayRecurring() public {
        // Mint and reveal first gobbler
        mintGobblerToAddress(users[0], 1);
        vm.warp(block.timestamp + 1 days);
        setRandomnessAndReveal(1, "seed");
        // Attempt reveal before 24 hours have passed
        mintGobblerToAddress(users[0], 1);
        vm.expectRevert(ArtGobblers.RequestTooEarly.selector);
        gobblers.requestRandomSeed();
    }

    /// @notice Test that seed can't be set without first revealing pending gobblers.
    function testCantSetRandomSeedWithoutRevealing() public {
        mintGobblerToAddress(users[0], 2);
        vm.warp(block.timestamp + 1 days);
        setRandomnessAndReveal(1, "seed");
        vm.warp(block.timestamp + 1 days);
        // should fail since there is one remaining gobbler to be revealed with seed
        vm.expectRevert(ArtGobblers.RevealsPending.selector);
        setRandomnessAndReveal(1, "seed");
    }

    /// @notice Test that revevals work as expected
    function testMultiReveal() public {
        mintGobblerToAddress(users[0], 100);
        // first 100 gobblers should be unrevealed
        for (uint256 i = 1; i <= 100; i++) {
            assertEq(gobblers.uri(i), gobblers.UNREVEALED_URI());
        }

        vm.warp(block.timestamp + 1 days); // can only reveal every 24 hours

        setRandomnessAndReveal(50, "seed");
        // first 50 gobblers should now be revealed
        for (uint256 i = 1; i <= 50; i++) {
            assertTrue(!stringEquals(gobblers.uri(i), gobblers.UNREVEALED_URI()));
        }
        // and next 50 should remain unrevealed
        for (uint256 i = 51; i <= 100; i++) {
            assertTrue(stringEquals(gobblers.uri(i), gobblers.UNREVEALED_URI()));
        }
    }

    function testCannotReuseSeedForReveal() public {
        // first mint and reveal.
        mintGobblerToAddress(users[0], 1);
        vm.warp(block.timestamp + 1 days);
        setRandomnessAndReveal(1, "seed");
        // seed used for first reveal.
        (uint64 firstSeed, , , , ) = gobblers.gobblerRevealsData();
        // second mint.
        mintGobblerToAddress(users[0], 1);
        vm.warp(block.timestamp + 1 days);
        gobblers.requestRandomSeed();
        // seed we want to use for second reveal.
        (uint64 secondSeed, , , , ) = gobblers.gobblerRevealsData();
        // verify that we are trying to use the same seed.
        assertEq(firstSeed, secondSeed);
        // try to reveal with same seed, which should fail.
        vm.expectRevert(ArtGobblers.SeedPending.selector);
        gobblers.revealGobblers(1);
        assertTrue(true);
    }

    /*//////////////////////////////////////////////////////////////
                                  GOO
    //////////////////////////////////////////////////////////////*/

    /// @notice test that goo balance grows as expected.
    function testSimpleRewards() public {
        mintGobblerToAddress(users[0], 1);
        // balance should initially be zero
        assertEq(gobblers.gooBalance(users[0]), 0);
        vm.warp(block.timestamp + 100000);
        // balance should be zero while no reveal
        assertEq(gobblers.gooBalance(users[0]), 0);
        setRandomnessAndReveal(1, "seed");
        // balance should NOT grow on same timestamp after reveal
        assertEq(gobblers.gooBalance(users[0]), 0);
        vm.warp(block.timestamp + 100000);
        // balance should grow after reveal
        assertGt(gobblers.gooBalance(users[0]), 0);
    }

    /// @notice Test that goo removal works as expected.
    function testGooRemoval() public {
        mintGobblerToAddress(users[0], 1);
        vm.warp(block.timestamp + 1 days);
        setRandomnessAndReveal(1, "seed");
        vm.warp(block.timestamp + 100000);
        uint256 initialBalance = gobblers.gooBalance(users[0]);
        uint256 removalAmount = initialBalance / 10; //10%
        vm.prank(users[0]);
        gobblers.removeGoo(removalAmount);
        uint256 finalBalance = gobblers.gooBalance(users[0]);
        // balance should change
        assertTrue(initialBalance != finalBalance);
        assertEq(initialBalance, finalBalance + removalAmount);
        // user should have removed goo
        assertEq(goo.balanceOf(users[0]), removalAmount);
    }

    /// @notice Test that goo can't be removed by a different user.
    function testCantRemoveGoo() public {
        mintGobblerToAddress(users[0], 1);
        vm.warp(block.timestamp + 100000);
        setRandomnessAndReveal(1, "seed");
        vm.prank(users[1]);
        vm.expectRevert(stdError.arithmeticError);
        gobblers.removeGoo(1);
    }

    /// @notice Test that adding goo is reflected in balance.
    function testGooAddition() public {
        mintGobblerToAddress(users[0], 1);
        assertEq(gobblers.getGobblerEmissionMultiple(1), 0);
        assertEq(gobblers.getUserEmissionMultiple(users[0]), 0);
        // waiting after mint to reveal shouldn't affect balance
        vm.warp(block.timestamp + 100000);
        assertEq(gobblers.gooBalance(users[0]), 0);
        setRandomnessAndReveal(1, "seed");
        uint256 gobblerMultiple = gobblers.getGobblerEmissionMultiple(1);
        assertGt(gobblerMultiple, 0);
        assertEq(gobblers.getUserEmissionMultiple(users[0]), gobblerMultiple);
        vm.prank(address(gobblers));
        uint256 additionAmount = 1000;
        goo.mintForGobblers(users[0], additionAmount);
        vm.prank(users[0]);
        gobblers.addGoo(additionAmount);
        assertEq(gobblers.gooBalance(users[0]), additionAmount);
    }

    /// @notice Test that emission multiple changes as expected after transfer.
    function testEmissionMultipleUpdatesAfterTransfer() public {
        mintGobblerToAddress(users[0], 1);
        vm.warp(block.timestamp + 1 days);
        setRandomnessAndReveal(1, "seed");

        uint256 initialUserMultiple = gobblers.getUserEmissionMultiple(users[0]);
        assertGt(initialUserMultiple, 0);
        assertEq(gobblers.getUserEmissionMultiple(users[1]), 0);

        vm.prank(users[0]);
        gobblers.safeTransferFrom(users[0], users[1], 1, 1, "");

        assertEq(gobblers.getUserEmissionMultiple(users[0]), 0);
        assertEq(gobblers.getUserEmissionMultiple(users[1]), initialUserMultiple);
    }

    /// @notice Test that gobbler balances are accurate after transfer.
    function testGobblerBalancesAfterTransfer() public {
        mintGobblerToAddress(users[0], 1);
        vm.warp(block.timestamp + 1 days);
        setRandomnessAndReveal(1, "seed");

        vm.warp(block.timestamp + 1000000);

        uint256 userOneBalance = gobblers.gooBalance(users[0]);
        uint256 userTwoBalance = gobblers.gooBalance(users[1]);
        //user with gobbler should have non-zero balance
        assertGt(userOneBalance, 0);
        //other user should have zero balance
        assertEq(userTwoBalance, 0);
        //transfer gobblers
        vm.prank(users[0]);
        gobblers.safeTransferFrom(users[0], users[1], 1, 1, "");
        //balance should not change after transfer
        assertEq(gobblers.gooBalance(users[0]), userOneBalance);
        assertEq(gobblers.gooBalance(users[1]), userTwoBalance);
    }

    /*//////////////////////////////////////////////////////////////
                               FEEDING ART
    //////////////////////////////////////////////////////////////*/

    /// @notice Test that pages can be fed to gobblers.
    function testFeedingArt() public {
        address user = users[0];
        mintGobblerToAddress(user, 1);
        uint256 pagePrice = pages.pagePrice();
        vm.prank(address(gobblers));
        goo.mintForGobblers(user, pagePrice);
        vm.startPrank(user);
        pages.mintFromGoo(type(uint256).max);
        gobblers.feedArt(1, address(pages), 1, false);
        vm.stopPrank();
        assertEq(gobblers.getCopiesOfArtFedToGobbler(1, address(pages), 1), 1);
    }

    /// @notice Test that you can't feed art to gobblers you don't own.
    function testCantFeedArtToUnownedGobbler() public {
        address user = users[0];
        uint256 pagePrice = pages.pagePrice();
        vm.prank(address(gobblers));
        goo.mintForGobblers(user, pagePrice);
        vm.startPrank(user);
        pages.mintFromGoo(type(uint256).max);
        vm.expectRevert(abi.encodeWithSelector(ArtGobblers.OwnerMismatch.selector, address(0)));
        gobblers.feedArt(1, address(pages), 1, false);
        vm.stopPrank();
    }

    /// @notice Test that you can't feed art you don't own to your gobbler.
    function testCantFeedUnownedArt() public {
        address user = users[0];
        mintGobblerToAddress(user, 1);
        vm.startPrank(user);
        vm.expectRevert("WRONG_FROM");
        gobblers.feedArt(1, address(pages), 1, false);
        vm.stopPrank();
    }

    function testCantFeed721As1155() public {
        address user = users[0];
        mintGobblerToAddress(user, 1);
        uint256 pagePrice = pages.pagePrice();
        vm.prank(address(gobblers));
        goo.mintForGobblers(user, pagePrice);
        vm.startPrank(user);
        pages.mintFromGoo(type(uint256).max);
        vm.expectRevert();
        gobblers.feedArt(1, address(pages), 1, true);
    }

    function testFeeding1155() public {
        address user = users[0];
        mintGobblerToAddress(user, 1);
        MockERC1155 token = new MockERC1155();
        token.mint(user, 0, 1, "");
        vm.startPrank(user);
        token.setApprovalForAll(address(gobblers), true);
        gobblers.feedArt(1, address(token), 0, true);
        vm.stopPrank();
        assertEq(gobblers.getCopiesOfArtFedToGobbler(1, address(token), 0), 1);
    }

    function testFeedingMultiple1155Copies() public {
        address user = users[0];
        mintGobblerToAddress(user, 1);
        MockERC1155 token = new MockERC1155();
        token.mint(user, 0, 5, "");
        vm.startPrank(user);
        token.setApprovalForAll(address(gobblers), true);
        gobblers.feedArt(1, address(token), 0, true);
        gobblers.feedArt(1, address(token), 0, true);
        gobblers.feedArt(1, address(token), 0, true);
        gobblers.feedArt(1, address(token), 0, true);
        gobblers.feedArt(1, address(token), 0, true);
        vm.stopPrank();
        assertEq(gobblers.getCopiesOfArtFedToGobbler(1, address(token), 0), 5);
    }

    function testCantFeed1155As721() public {
        address user = users[0];
        mintGobblerToAddress(user, 1);
        MockERC1155 token = new MockERC1155();
        token.mint(user, 0, 1, "");
        vm.startPrank(user);
        token.setApprovalForAll(address(gobblers), true);
        vm.expectRevert();
        gobblers.feedArt(1, address(token), 0, false);
    }

    /*//////////////////////////////////////////////////////////////
                           LONG-RUNNING TESTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Check that max supply is mintable
    function testLongRunningMintMaxFromGoo() public {
        uint256 maxMintableWithGoo = gobblers.MAX_MINTABLE();

        for (uint256 i = 0; i < maxMintableWithGoo; i++) {
            vm.warp(block.timestamp + 1 days);
            uint256 cost = gobblers.gobblerPrice();
            vm.prank(address(gobblers));
            goo.mintForGobblers(users[0], cost);
            vm.prank(users[0]);
            gobblers.mintFromGoo(type(uint256).max);
        }
    }

    /// @notice Check that minting beyond max supply should revert.
    function testLongRunningMintMaxFromGooRevert() public {
        uint256 maxMintableWithGoo = gobblers.MAX_MINTABLE();

        for (uint256 i = 0; i < maxMintableWithGoo + 1; i++) {
            vm.warp(block.timestamp + 1 days);

            if (i == maxMintableWithGoo) vm.expectRevert("UNDEFINED");
            uint256 cost = gobblers.gobblerPrice();

            vm.prank(address(gobblers));
            goo.mintForGobblers(users[0], cost);
            vm.prank(users[0]);

            if (i == maxMintableWithGoo) vm.expectRevert("UNDEFINED");
            gobblers.mintFromGoo(type(uint256).max);
        }
    }

    /// @notice Check that max reserved supplies are mintable.
    function testLongRunningMintMaxReserved() public {
        uint256 maxMintableWithGoo = gobblers.MAX_MINTABLE();

        for (uint256 i = 0; i < maxMintableWithGoo; i++) {
            vm.warp(block.timestamp + 1 days);
            uint256 cost = gobblers.gobblerPrice();
            vm.prank(address(gobblers));
            goo.mintForGobblers(users[0], cost);
            vm.prank(users[0]);
            gobblers.mintFromGoo(type(uint256).max);
        }

        gobblers.mintReservedGobblers(gobblers.RESERVED_SUPPLY() / 2);
    }

    /// @notice Check that minting reserves beyond their max supply reverts.
    function testLongRunningMintMaxTeamRevert() public {
        uint256 maxMintableWithGoo = gobblers.MAX_MINTABLE();

        for (uint256 i = 0; i < maxMintableWithGoo; i++) {
            vm.warp(block.timestamp + 1 days);
            uint256 cost = gobblers.gobblerPrice();
            vm.prank(address(gobblers));
            goo.mintForGobblers(users[0], cost);
            vm.prank(users[0]);
            gobblers.mintFromGoo(type(uint256).max);
        }

        gobblers.mintReservedGobblers(gobblers.RESERVED_SUPPLY() / 2);

        vm.expectRevert(ArtGobblers.ReserveImbalance.selector);
        gobblers.mintReservedGobblers(1);
    }

    /*//////////////////////////////////////////////////////////////
                                 HELPERS
    //////////////////////////////////////////////////////////////*/

    /// @notice Mint a number of gobblers to the given address
    function mintGobblerToAddress(address addr, uint256 num) internal {
        for (uint256 i = 0; i < num; i++) {
            vm.startPrank(address(gobblers));
            goo.mintForGobblers(addr, gobblers.gobblerPrice());
            vm.stopPrank();

            vm.prank(addr);
            gobblers.mintFromGoo(type(uint256).max);
        }
    }

    /// @notice Call back vrf with randomness and reveal gobblers.
    function setRandomnessAndReveal(uint256 numReveal, string memory seed) internal {
        bytes32 requestId = gobblers.requestRandomSeed();
        uint256 randomness = uint256(keccak256(abi.encodePacked(seed)));
        // call back from coordinator
        vrfCoordinator.callBackWithRandomness(requestId, randomness, address(gobblers));
        gobblers.revealGobblers(numReveal);
    }

    /// @notice Check for string equality.
    function stringEquals(string memory s1, string memory s2) internal pure returns (bool) {
        return keccak256(abi.encodePacked(s1)) == keccak256(abi.encodePacked(s2));
    }

    function mintNextLegendary(address addr) internal {
        uint256[] memory id;
        mintGobblerToAddress(addr, gobblers.LEGENDARY_AUCTION_INTERVAL() * 2);
        vm.prank(addr);
        gobblers.mintLegendaryGobbler(id);
    }
}
