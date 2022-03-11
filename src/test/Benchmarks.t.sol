// SPDX-License-Identifier: Unlicense
pragma solidity >=0.8.0;

import {DSTest} from "ds-test/test.sol";
import {Utilities} from "./utils/Utilities.sol";
import {console} from "./utils/Console.sol";
import {Vm} from "forge-std/Vm.sol";
import {ArtGobblers} from "../ArtGobblers.sol";
import {Goop} from "../Goop.sol";
import {Pages} from "../Pages.sol";
import {LinkToken} from "./utils/mocks/LinkToken.sol";
import {VRFCoordinatorMock} from "./utils/mocks/VRFCoordinatorMock.sol";
import {Strings} from "openzeppelin/utils/Strings.sol";

contract BenchmarksTest is DSTest {
    using Strings for uint256;

    Vm internal immutable vm = Vm(HEVM_ADDRESS);

    Utilities internal utils;
    address payable[] internal users;

    ArtGobblers private gobblers;
    VRFCoordinatorMock private vrfCoordinator;
    LinkToken private linkToken;

    Goop goop;
    Pages pages;

    bytes32 private keyHash;
    uint256 private fee;
    string private baseUri = "base";

    function setUp() public {
        utils = new Utilities();
        users = utils.createUsers(5);
        linkToken = new LinkToken();
        vrfCoordinator = new VRFCoordinatorMock(address(linkToken));
        gobblers = new ArtGobblers(address(vrfCoordinator), address(linkToken), keyHash, fee, baseUri);
        goop = gobblers.goop();
        pages = gobblers.pages();

        // TODO: shouldn't need to prank here
        vm.startPrank(address(gobblers));
        pages.setMintStart(block.timestamp);
        goop.mint(address(this), 100000000e18);
        vm.stopPrank();

        gobblers.setMerkleRoot("root");
        gobblers.mintFromGoop();

        // TODO: legendary price reverts if we don't have this, probably shouldn't be like that.
        vm.warp(block.timestamp + 30 days);
    }

    function testPagePrice() public view {
        pages.pagePrice();
    }

    function testMintFromGoop() public {
        gobblers.mintFromGoop();
    }

    function testLegendaryGobblersPrice() public view {
        gobblers.legendaryGobblerPrice();
    }

    function testAddAndRemoveGoop() public {
        gobblers.addGoop(1, 1e18);
        gobblers.removeGoop(1, 1e18);
    }
}
