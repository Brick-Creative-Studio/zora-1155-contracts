// SPDX-License-Identifier: MIT
pragma solidity 0.8.17;

import "forge-std/Test.sol";
import {ProtocolRewards} from "@zoralabs/protocol-rewards/src/ProtocolRewards.sol";
import {ZoraCreator1155Impl} from "../../../src/nft/ZoraCreator1155Impl.sol";
import {Zora1155} from "../../../src/proxies/Zora1155.sol";
import {IZoraCreator1155Errors} from "../../../src/interfaces/IZoraCreator1155Errors.sol";
import {IMinter1155} from "../../../src/interfaces/IMinter1155.sol";
import {ICreatorRoyaltiesControl} from "../../../src/interfaces/ICreatorRoyaltiesControl.sol";
import {IZoraCreator1155Factory} from "../../../src/interfaces/IZoraCreator1155Factory.sol";
import {ILimitedMintPerAddress} from "../../../src/interfaces/ILimitedMintPerAddress.sol";
import {BondingCurveSaleStrategy} from "../../../src/minters/bonding-curve/BondingCurveSaleStrategy.sol";

contract BondingCurveSaleStrategyTest is Test {
    ZoraCreator1155Impl internal target;
    BondingCurveSaleStrategy internal bondingCurve;
    address payable internal admin = payable(address(0x999));
    address internal zora;
    address internal tokenRecipient;
    address internal fundsRecipient;

    event SaleSet(address indexed mediaContract, uint256 indexed tokenId, BondingCurveSaleStrategy.SalesConfig salesConfig);
    event MintComment(address indexed sender, address indexed tokenContract, uint256 indexed tokenId, uint256 quantity, string comment);

    function setUp() external {
        zora = makeAddr("zora");
        tokenRecipient = makeAddr("tokenRecipient");
        fundsRecipient = makeAddr("fundsRecipient");

        bytes[] memory emptyData = new bytes[](0);
        ProtocolRewards protocolRewards = new ProtocolRewards();
        ZoraCreator1155Impl targetImpl = new ZoraCreator1155Impl(zora, address(0), address(protocolRewards));
        Zora1155 proxy = new Zora1155(address(targetImpl));
        target = ZoraCreator1155Impl(address(proxy));
        target.initialize("test", "test", ICreatorRoyaltiesControl.RoyaltyConfiguration(0, 0, address(0)), admin, emptyData);
        bondingCurve = new BondingCurveSaleStrategy();
    }

    function test_ContractName() external {
        assertEq(bondingCurve.contractName(), "Bonding Curve Sale Strategy");
    }

    function test_Version() external {
        assertEq(bondingCurve.contractVersion(), "1.1.0");
    }

    function test_MintFlow() external {
        vm.startPrank(admin);
        uint256 newTokenId = target.setupNewToken("https://zora.co/testing/token.json", 10);
        target.addPermission(newTokenId, address(bondingCurve), target.PERMISSION_BIT_MINTER());
        vm.expectEmit(true, true, true, true);
        emit SaleSet(
            address(target),
            newTokenId,
            BondingCurveSaleStrategy.SalesConfig({
                saleStart: 0,
                saleEnd: type(uint64).max,
                basePricePerToken: 1 ether,
                scalingFactor: 110,
                fundsRecipient: fundsRecipient
            })
        );
        target.callSale(
            newTokenId,
            bondingCurve,
            abi.encodeWithSelector(
                BondingCurveSaleStrategy.setSale.selector,
                newTokenId,
                BondingCurveSaleStrategy.SalesConfig({
                    saleStart: 0,
                    saleEnd: type(uint64).max,
                    basePricePerToken: 1 ether,
                    scalingFactor: 110,
                    fundsRecipient: fundsRecipient
                })
            )
        );
        vm.stopPrank();

        uint256 numTokens = 1;
        uint256 totalReward = target.computeTotalReward(numTokens);
        uint256 totalValue = (1 ether * numTokens) + totalReward;

        vm.deal(tokenRecipient, totalValue);

        vm.startPrank(tokenRecipient);
        target.mint{value: totalValue}(bondingCurve, newTokenId, 1, abi.encode(tokenRecipient, ""));

        assertEq(target.balanceOf(tokenRecipient, newTokenId), 1);
        assertEq(address(target).balance, 1 ether);

        vm.stopPrank();
    }

    function test_SaleStart() external {
        vm.startPrank(admin);
        uint256 newTokenId = target.setupNewToken("https://zora.co/testing/token.json", 10);
        target.addPermission(newTokenId, address(bondingCurve), target.PERMISSION_BIT_MINTER());
        target.callSale(
            newTokenId,
            bondingCurve,
            abi.encodeWithSelector(
                BondingCurveSaleStrategy.setSale.selector,
                newTokenId,
                BondingCurveSaleStrategy.SalesConfig({
                    saleStart: uint64(block.timestamp + 1 days),
                    saleEnd: type(uint64).max,
                    basePricePerToken: 1 ether,
                    scalingFactor: 110,
                    fundsRecipient: fundsRecipient
                })
            )
        );
        vm.stopPrank();

        vm.deal(tokenRecipient, 20 ether);

        vm.expectRevert(abi.encodeWithSignature("SaleHasNotStarted()"));
        vm.prank(tokenRecipient);
        target.mint{value: 1 ether}(bondingCurve, newTokenId, 1, abi.encode(tokenRecipient, ""));
    }

    function test_SaleEnd() external {
        vm.warp(2 days);

        vm.startPrank(admin);
        uint256 newTokenId = target.setupNewToken("https://zora.co/testing/token.json", 10);
        target.addPermission(newTokenId, address(bondingCurve), target.PERMISSION_BIT_MINTER());
        target.callSale(
            newTokenId,
            bondingCurve,
            abi.encodeWithSelector(
                BondingCurveSaleStrategy.setSale.selector,
                newTokenId,
                BondingCurveSaleStrategy.SalesConfig({
                    saleStart: 0,
                    saleEnd: uint64(1 days),
                    basePricePerToken: 1 ether,
                    scalingFactor: 110,
                    fundsRecipient: fundsRecipient
                })
            )
        );
        vm.stopPrank();

        vm.deal(tokenRecipient, 20 ether);

        vm.expectRevert(abi.encodeWithSignature("SaleEnded()"));
        vm.prank(tokenRecipient);
        target.mint{value: 1 ether}(bondingCurve, newTokenId, 1, abi.encode(tokenRecipient, ""));
    }

    function test_PricePerToken() external {
        // should mint a few tokens and at each step check if the current price is the expected one
        uint256 totalValue = 1 ether;
        uint256 totalSecondValue = (1 ether * 110)/100 + 1 ether;
        uint256 newTokenId = target.setupNewToken("https://zora.co/testing/token.json", 10);
        uint256 secondNewTokenId = target.setupNewToken("https://zora.co/testing/token.json", 11);


        target.mint{value: totalValue}(bondingCurve, newTokenId, 1, abi.encode(tokenRecipient, ""));
        target.mint{value: totalSecondValue}(bondingCurve, secondNewTokenId, 1, abi.encode(tokenRecipient, ""));
    }

    // function test_FundsRecipient() external {
    //     vm.startPrank(admin);
    //     uint256 newTokenId = target.setupNewToken("https://zora.co/testing/token.json", 10);

    //     vm.deal(fundsRecipient, 0);

    //     vm.prank(fundsRecipient);
    //     bondingCurve.withdrawFunds(target, newTokenId, fundsRecipient);

    //     assertGt(fundsRecipient.balance, 0);
    // }

    // function test_ResetSale() external {
    //     vm.startPrank(admin);
    //     uint256 newTokenId = target.setupNewToken("https://zora.co/testing/token.json", 10);
    //     target.addPermission(newTokenId, address(bondingCurve), target.PERMISSION_BIT_MINTER());
    //     vm.expectEmit(false, false, false, false);
    //     emit SaleSet(
    //         address(target),
    //         newTokenId,
    //         BondingCurveSaleStrategy.SalesConfig({
    //                 saleStart: 0,
    //                 saleEnd: type(uint64).max,
    //                 basePricePerToken: 1 ether,
    //                 scalingFactor: 110,
    //                 fundsRecipient: fundsRecipient
    //         })
    //     );
    //     target.callSale(newTokenId, bondingCurve, abi.encodeWithSelector(BondingCurveSaleStrategy.resetSale.selector, newTokenId));
    //     vm.stopPrank();

    //     BondingCurveSaleStrategy.SalesConfig memory sale = bondingCurve.sale(address(target), newTokenId);
    //     assertEq(sale.pricePerToken, 0);
    //     assertEq(sale.saleStart, 0);
    //     assertEq(sale.saleEnd, 0);
    //     assertEq(sale.maxTokensPerAddress, 0);
    //     assertEq(sale.fundsRecipient, address(0));
    // }

    function test_bondingCurveSaleSupportsInterface() public {
        assertTrue(bondingCurve.supportsInterface(0x6890e5b3));
        assertTrue(bondingCurve.supportsInterface(0x01ffc9a7));
        assertFalse(bondingCurve.supportsInterface(0x0));
    }
}