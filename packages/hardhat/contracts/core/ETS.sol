// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts-upgradeable/utils/ContextUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/math/SafeMathUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC721/IERC721Upgradeable.sol";

import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

import "./ETSTag.sol";

/// @title ETS Core
/// @author Ethereum Tag Service <security@ets.xyz>
/// @notice Core tagging contract that enables any online target to be tagged with an ETSTAG token.
/// @dev ETS Core utilizes Open Zeppelin UUPS upgradability pattern.
contract ETS is Initializable, ContextUpgradeable, ReentrancyGuardUpgradeable, UUPSUpgradeable {
    using SafeMathUpgradeable for uint256;

    /// Storage

    /// @dev ETS access controls contract.
    ETSAccessControls public accessControls;

    /// @dev ETSTAG erc-721 token contract.
    ETSTag public etsTag;

    /// @notice Percentage of tagging fee allocated to ETS.
    uint256 public platformPercentage;

    /// @notice Percentage of tagging fee allocated to Publisher.
    uint256 public publisherPercentage;

    /// @notice Percentage of tagging fee allocated to Creator or Owner.
    uint256 public remainingPercentage;

    /// @dev Incremental tagging record counter. Used for tagging record ID.
    uint256 public taggingCounter;

    /// @notice Fee in ETH Collected by ETS for tagging.
    uint256 public taggingFee;

    /// @dev Map for holding amount accrued to participant address wallets.
    mapping(address => uint256) public accrued;

    /// @dev Map for holding lifetime amount drawn down from accrued by participants.
    mapping(address => uint256) public paid;

    /// @dev Map for holding permitted tagging target chain ids.
    mapping(uint256 => bool) public permittedNftChainIds;

    /// @dev Map of tagging id to tagging record.
    mapping(uint256 => TaggingRecord) public taggingRecords;


    /// Public constants

    string public constant NAME = "ETS Core";
    string public constant VERSION = "0.2.0";
    uint256 public constant modulo = 100;

    /// Structs

    /// Data structure for a tagging record.
    struct TaggingRecord {
        uint256 etsTagId;
        address nftContract;
        uint256 nftId;
        address tagger;
        uint256 timestamp;
        address publisher;
        uint256 nftChainId;
    }

    /// Events

    event TargetTagged(
        uint256 taggingId
    );

    event FundsWithdrawn(
        address indexed who,
        uint256 amount
    );

    event TaggingFeeSet(
        uint256 previousFee,
        uint256 taggingFee
    );

    event AccessControlsUpdated(
        ETSAccessControls previousAccessControls, 
        ETSAccessControls newAccessControls
    );

    event PercentagesSet(
        uint256 platformPercentage,
        uint256 publisherPercentage,
        uint256 remainingPercentage
    );

    event PermittedNftChainIdSet(
        uint256 nftChainId,
        bool setting
    );

    /// Modifiers

    /// @dev When applied to a method, only allows execution when the sender has the admin role.
    modifier onlyAdmin() {
        require(accessControls.isAdmin(_msgSender()), "Caller must be admin");
        _;
    }

    /// @dev Replaces contructor function for UUPS Proxy contracts. Called upon first deployment.
    function initialize(ETSAccessControls _accessControls, ETSTag _etsTag) public initializer {
        accessControls = _accessControls;
        etsTag = _etsTag;
        taggingCounter = 0;
        taggingFee = 0.001 ether;
        platformPercentage = 20;
        publisherPercentage = 30;
        remainingPercentage = 50;
    }

    // Ensure that only address with admin role can upgrade.
    function _authorizeUpgrade(address) internal override onlyAdmin {}

    // External write

    /// @notice Combines the action of creating a new tag nft (ETSTAG) and then tagging an NFT asset with this new tag.
    /// @dev Only a whitelisted publisher can execute this with the required fee unless the caller / sender has admin privileges.
    /// @param _tagString string value of the tag to be minted.
    /// @param _nftContract address of nft contract.
    /// @param _nftId ID of the nft to link from the above nft contract.
    /// @param _publisher the publisher attributed to the tagging.
    /// @param _tagger the ethereum account that made the original tagging request.
    /// @param _nftChainId EVM compatible chain id.
    function mintAndTag(
        string calldata _tagString,
        address _nftContract,
        uint256 _nftId,
        address payable _publisher,
        address _tagger,
        uint256 _nftChainId
    ) external payable {
        require(accessControls.isPublisher(_publisher), "Mint and tag: The publisher must be whitelisted");
        require(msg.value >= taggingFee, "Mint and tag: You must send the tag fee");
        require(this.getPermittedNftChainId(_nftChainId), "Mint and tag: Tagging target chain not permitted");

        uint256 etsTagId = etsTag.mint(_tagString, _publisher, _tagger);
        _tag(etsTagId, _nftContract, _nftId, _publisher, _tagger, _nftChainId);
    }

    /// @notice Tag a target with an tag string.
    /// @dev If tag string does not exist as a ETSTAG token, function will attempt to mint a new one.
    /// @param _tagString tag string used for tagging.
    /// @param _nftContract address of nft contract.
    /// @param _nftId ID of the nft to link from the above nft contract.
    /// @param _tagger the ethereum account that made the original tagging request.
    /// @param _nftChainId EVM compatible chain id.
    function tag(
        string calldata _tagString,
        address _nftContract,
        uint256 _nftId,
        address payable _publisher,
        address _tagger,
        uint256 _nftChainId
    ) public payable nonReentrant {
        require(accessControls.isPublisher(_publisher), "Tag: The publisher must be whitelisted");
        require(msg.value >= taggingFee, "Tag: You must send the fee");
        require(this.getPermittedNftChainId(_nftChainId), "Tag: Tagging target chain not permitted");

        uint256 etsTagId = etsTag.getTagId(_tagString);
        if (etsTagId == 0) {
            etsTagId = etsTag.mint(_tagString, _publisher, _tagger);
        }

        _tag(etsTagId, _nftContract, _nftId, _publisher, _tagger, _nftChainId);
    }

    /// @notice Enables anyone to send ETH accrued by an account.
    /// @dev Can be called by the account owner or on behalf of someone.
    /// @dev Does nothing when there is nothing due to the account.
    /// @param _account Target address that has had accrued ETH and which will receive the ETH.
    function drawDown(address payable _account) external nonReentrant {
        uint256 balanceDue = accrued[_account].sub(paid[_account]);
        if (balanceDue > 0 && balanceDue <= address(this).balance) {
            paid[_account] = paid[_account].add(balanceDue);
            _account.transfer(balanceDue);

            emit FundsWithdrawn(_account, balanceDue);
        }
    }

    /// @notice Sets the fee required to tag an NFT asset.
    /// @param _fee Value of the fee in WEI.
    function setTaggingFee(uint256 _fee) external onlyAdmin {
        uint previousFee = taggingFee;
        taggingFee = _fee;
        emit TaggingFeeSet(previousFee, taggingFee);
    }

    /// @notice Admin functionality for updating the access controls.
    /// @param _accessControls Address of the access controls contract.
    function updateAccessControls(ETSAccessControls _accessControls) external onlyAdmin {
        require(address(_accessControls) != address(0), "ETS.updateAccessControls: Cannot be zero");
        ETSAccessControls prevAccessControls = accessControls;
        accessControls = _accessControls;
        emit AccessControlsUpdated(prevAccessControls, accessControls);
    }

    /// @notice Admin functionality for updating the percentages.
    /// @param _platformPercentage percentage for platform.
    /// @param _publisherPercentage percentage for publisher.
    function updatePercentages(uint256 _platformPercentage, uint256 _publisherPercentage) external onlyAdmin {
        require(
            _platformPercentage.add(_publisherPercentage) <= 100,
            "ETS.updatePercentages: percentages must not be over 100"
        );
        platformPercentage = _platformPercentage;
        publisherPercentage = _publisherPercentage;
        remainingPercentage = modulo.sub(platformPercentage).sub(publisherPercentage);
        
        emit PercentagesSet(platformPercentage, publisherPercentage, remainingPercentage);
    }

    /// @notice Admin functionality for enabling/disabling target chains.
    /// @param _nftChainId EVM compatible chain id.
    /// @param _setting Boolean, set true for enabled, false for disabled.
    function setPermittedNftChainId(uint256 _nftChainId, bool _setting) external onlyAdmin {
        permittedNftChainIds[_nftChainId] = _setting;
        emit PermittedNftChainIdSet(_nftChainId, _setting);
    }

    /// External read

    /// @notice Used to check how much ETH has been accrued by an address factoring in amount paid out.
    /// @param _account Address of the account being queried.
    /// @return _due Amount of WEI in ETH due to account.
    function totalDue(address _account) external view returns (uint256 _due) {
        return accrued[_account].sub(paid[_account]);
    }

    /// @dev Retrieves a tagging record.
    /// @param _taggingId ID of the tagging record.
    /// @return _etsTagId token ID of ETSTAG used.
    /// @return _nftContract NFT contract address.
    /// @return _nftId NFT ID.
    /// @return _tagger Address that tagged the NFT asset.
    /// @return _timestamp When the tag took place.
    /// @return _publisher Publisher through which the tag took place.
    /// @return _nftChainId Chain ID target NFT lives on.
    function getTaggingRecord(uint256 _taggingId)
        external
        view
        returns (
            uint256 _etsTagId,
            address _nftContract,
            uint256 _nftId,
            address _tagger,
            uint256 _timestamp,
            address _publisher,
            uint256 _nftChainId
        )
    {
        TaggingRecord storage taggingRecord = taggingRecords[_taggingId];
        return (
            taggingRecord.etsTagId,
            taggingRecord.nftContract,
            taggingRecord.nftId,
            taggingRecord.tagger,
            taggingRecord.timestamp,
            taggingRecord.publisher,
            taggingRecord.nftChainId
        );
    }

    /// @notice Check if a target chain is permitted for tagging.
    /// @param _nftChainId EVM compatible chain id.
    /// @return true for enabled, false for disabled.
    function getPermittedNftChainId(uint256 _nftChainId) external view returns (bool) {
        return permittedNftChainIds[_nftChainId];
    }

    function version() external pure returns (string memory) {
        return VERSION;
    }

    /// Internal write

    function _tag(
        uint256 _etsTagId,
        address _nftContract,
        uint256 _nftId,
        address _publisher,
        address _tagger,
        uint256 _nftChainId
    ) private {
        // might remove this limitation.
        require(
            _nftContract != address(etsTag),
            "Tag: Tagging other tags is not permitted"
        );
        // Ensure that we are dealing with an ERC721 compliant _nftContract
        require(_nftContract != address(0), "function call to a non-contract address");

        // Generate a new taggging record id.
        taggingCounter = taggingCounter.add(1);
        uint256 taggingId = taggingCounter;

        taggingRecords[taggingId] = TaggingRecord({
            etsTagId: _etsTagId,
            nftContract: _nftContract,
            nftId: _nftId,
            tagger: _tagger,
            timestamp: block.timestamp,
            publisher: _publisher,
            nftChainId: _nftChainId
        });

        (address _platform, address _owner) = etsTag.getPaymentAddresses(_etsTagId);

        // pre-auction.
        if (_owner == _platform) {
            accrued[_platform] = accrued[_platform].add(msg.value.mul(platformPercentage).div(modulo));
            accrued[_publisher] = accrued[_publisher].add(msg.value.mul(publisherPercentage).div(modulo));

            address creator = etsTag.getCreatorAddress(_etsTagId);
            accrued[creator] = accrued[creator].add(msg.value.mul(remainingPercentage).div(modulo));
        }
        // post-auction.
        else {
            accrued[_platform] = accrued[_platform].add(msg.value.mul(platformPercentage).div(modulo));
            accrued[_publisher] = accrued[_publisher].add(msg.value.mul(publisherPercentage).div(modulo));

            accrued[_owner] = accrued[_owner].add(msg.value.mul(remainingPercentage).div(modulo));
        }

        // Log that a target has been tagged.
        emit TargetTagged(taggingId);
    }
}
