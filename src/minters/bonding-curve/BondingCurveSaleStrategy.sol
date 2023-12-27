// SPDX-License-Identifier: MIT
pragma solidity 0.8.17;

import {Enjoy} from "_imagine/mint/Enjoy.sol";
import {IMinter1155} from "../../interfaces/IMinter1155.sol";
import {ICreatorCommands} from "../../interfaces/ICreatorCommands.sol";
import {SaleStrategy} from "../SaleStrategy.sol";
import {SaleCommandHelper} from "../utils/SaleCommandHelper.sol";
import {LimitedMintPerAddress} from "../utils/LimitedMintPerAddress.sol";

import {ISplitMain} from "./ISplitMain.sol";

/// @title BondingCurveSaleStrategy
/// @notice A sale strategy for ZoraCreator that allows for sales priced on a bonding curve
/// @author @ghiliweld
contract BondingCurveSaleStrategy is Enjoy, SaleStrategy, LimitedMintPerAddress {
    struct SalesConfig {
        /// @notice Unix timestamp for the sale start
        uint64 saleStart;
        /// @notice Unix timestamp for the sale end
        uint64 saleEnd;
        /// @notice Base price per token in eth wei
        uint96 basePricePerToken;
        /// @notice Scaling factor that controls how the price grows
        uint96 scalingFactor;
        /// @notice Funds recipient (0 if no different funds recipient than the contract global)
        address fundsRecipient;
    }

    // target -> tokenId -> settings
    mapping(address => mapping(uint256 => SalesConfig)) internal salesConfigs;
    
    // target -> tokenId -> token price
    mapping(address => mapping(uint256 => uint256)) internal tokenPrices;

    mapping(address => mapping(uint256 => uint256)) internal funds;

    ISplitMain public splitMain = ISplitMain(0x2ed6c4B5dA6378c7897AC67Ba9e43102Feb694EE);

    using SaleCommandHelper for ICreatorCommands.CommandSet;

    function contractURI() external pure override returns (string memory) {
        return "https://github.com/ourzora/zora-1155-contracts/";
    }

    /// @notice The name of the sale strategy
    function contractName() external pure override returns (string memory) {
        return "Bonding Curve Sale Strategy";
    }

    /// @notice The version of the sale strategy
    function contractVersion() external pure override returns (string memory) {
        return "1.1.0";
    }

    error WrongValueSent(uint256 expectedValue);
    error SaleEnded();
    error SaleHasNotStarted();
    error SaleHasNotEnded();
    error UnauthorizedWithdraw();

    event SaleSet(address indexed mediaContract, uint256 indexed tokenId, SalesConfig salesConfig);
    event MintComment(address indexed sender, address indexed tokenContract, uint256 indexed tokenId, uint256 quantity, string comment);
    event Withdraw(address indexed recipient, uint256 indexed tokenId, uint256 amount);

    /// @notice Compiles and returns the commands needed to mint a token using this sales strategy
    /// @param tokenId The token ID to mint
    /// @param ethValueSent The amount of ETH sent with the transaction
    /// @param minterArguments The arguments passed to the minter, which should be the address to mint to
    function requestMint(
        address,
        uint256 tokenId,
        uint256,
        uint256 ethValueSent,
        bytes calldata minterArguments
    ) external returns (ICreatorCommands.CommandSet memory commands) {
        address mintTo;
        string memory comment = "";
        if (minterArguments.length == 32) {
            mintTo = abi.decode(minterArguments, (address));
        } else {
            (mintTo, comment) = abi.decode(minterArguments, (address, string));
        }

        SalesConfig storage config = salesConfigs[msg.sender][tokenId];

        // If sales config does not exist this first check will always fail.

        // Check sale end
        if (block.timestamp > config.saleEnd) {
            revert SaleEnded();
        }

        // Check sale start
        if (block.timestamp < config.saleStart) {
            revert SaleHasNotStarted();
        }

        // bonding curve math to compute new price, inspired by stealcam bonding curve
        uint256 currentPrice = tokenPrices[msg.sender][tokenId];
        uint256 newPrice = (currentPrice * config.scalingFactor) / 100 + config.basePricePerToken;
        // Check value sent
        if (newPrice != ethValueSent) {
            revert WrongValueSent({
                expectedValue: newPrice
                });
        }
        tokenPrices[msg.sender][tokenId] = newPrice;

        bool shouldTransferFunds = config.fundsRecipient != address(0);
        commands.setSize(shouldTransferFunds ? 2 : 1);

        // Mint command
        commands.mint(mintTo, tokenId, 1);

        if (bytes(comment).length > 0) {
            emit MintComment(mintTo, msg.sender, tokenId, 1, comment);
        }

        if (shouldTransferFunds) {
            commands.transfer(config.fundsRecipient, ethValueSent);
        }

        funds[msg.sender][tokenId] += ethValueSent;
    }

    /// @notice Allows the fundsRecipient of a sale withdraw their funds
    function withdrawFunds(address factory, uint256 tokenId, bytes calldata splitArgs) external returns (address split) {
        SalesConfig storage config = salesConfigs[factory][tokenId];
        
        address recipient = config.fundsRecipient;

        if (msg.sender != recipient) {
            revert UnauthorizedWithdraw();
        }

        // Check sale end
        if (block.timestamp < config.saleEnd) {
            revert SaleHasNotEnded();
        }

        uint256 amount = funds[factory][tokenId];
        funds[factory][tokenId] = 0;

        (address[] memory accounts, uint32[] memory percentAllocations) = abi.decode(splitArgs, (address[] , uint32[]));

        // create split
        split = splitMain.createSplit(
            accounts, 
            percentAllocations, 
            0,
            address(0)
        );

        // forward funds to split
        (bool success, ) = split.call{value: amount}("");

        // distribute funds
        splitMain.distributeETH(
            split,
            accounts, 
            percentAllocations, 
            0,
            address(0)
        );

        // Emit event
        emit Withdraw(recipient, tokenId, amount);
    }

    /// @notice Sets the sale config for a given token
    function setSale(uint256 tokenId, SalesConfig memory salesConfig) external {
        salesConfigs[msg.sender][tokenId] = salesConfig;

        // Emit event
        emit SaleSet(msg.sender, tokenId, salesConfig);
    }

    /// @notice Deletes the sale config for a given token
    function resetSale(uint256 tokenId) external override {
        delete salesConfigs[msg.sender][tokenId];

        // Deleted sale emit event
        emit SaleSet(msg.sender, tokenId, salesConfigs[msg.sender][tokenId]);
    }

    /// @notice Returns the sale config for a given token
    function sale(address tokenContract, uint256 tokenId) external view returns (SalesConfig memory) {
        return salesConfigs[tokenContract][tokenId];
    }

    function getLastTokenPrice(uint256 tokenId) external view returns (uint256) {
        return tokenPrices[msg.sender][tokenId];
    }

    /// @notice Returns latest token price
   function getLatestPrice(address tokenContract, uint256 tokenId) public view returns (uint256) {
        SalesConfig storage config = salesConfigs[tokenContract][tokenId];

        uint256 currentPrice = tokenPrices[tokenContract][tokenId];
        uint256 newPrice = (currentPrice * config.scalingFactor) / 100 + config.basePricePerToken;

        return newPrice;
    }


    function supportsInterface(bytes4 interfaceId) public pure virtual override(LimitedMintPerAddress, SaleStrategy) returns (bool) {
        return super.supportsInterface(interfaceId) || SaleStrategy.supportsInterface(interfaceId);
    }
}