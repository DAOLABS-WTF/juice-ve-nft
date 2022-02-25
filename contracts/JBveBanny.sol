// SPDX-License-Identifier: MIT
pragma solidity 0.8.6;

import '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import '@openzeppelin/contracts/token/ERC721/extensions/draft-ERC721Votes.sol';
import '@openzeppelin/contracts/token/ERC721/extensions/ERC721Enumerable.sol';
import '@openzeppelin/contracts/access/Ownable.sol';
import '@openzeppelin/contracts/security/ReentrancyGuard.sol';
import '@paulrberg/contracts/math/PRBMath.sol';
import '@jbx-protocol/contracts-v2/contracts/interfaces/IJBTokenStore.sol';

import './utils/ITokenUriResolver.sol';

//*********************************************************************//
// --------------------------- custom errors ------------------------- //
//*********************************************************************//
error INVALID_ACCOUNT();
error INSUFFICIENT_BALANCE();
error INSUFFICIENT_ALLOWANCE();
error LOCK_PERIOD_NOT_OVER();
error INVALID_DURATION();

/**
  @notice
  Allows any ERC20 Token Holders to stake their tokens and receive a Banny based on their stake and lock in period.
  @dev 
  Bannies are transferrable, will be burnt when the stake is claimed before or after the lock-in period ends.
  The Token URI will be determined by SVG for each banny category.
  Inherits from:
  ERC721Votes - for ERC721 and governance support.
  Ownable - for access control.
  ReentrancyGuard - for protection against external calls.
*/
contract JBveBanny is ERC721Votes, ERC721Enumerable, Ownable, ReentrancyGuard {
  event Lock(
    address account,
    uint256 amount,
    uint256 duration,
    address beneficiary,
    uint256 lockedUntil,
    address caller
  );

  event Unlock(uint256 tokenId, address beneficiary, uint256 amount, address caller);

  event ExtendLock(uint256 tokenId, uint256 updatedDuration, address caller);

  event SetUriResolver(ITokenUriResolver resolver, address caller);
  //*********************************************************************//
  // ----------------------------- constants --------------------------- //
  //*********************************************************************//
  uint256 public constant _ONE_THOUSAND_DAYS = 8640000;
  uint256 public constant _TWO_HUNDRED_FIFTY_DAYS = 21600000;
  uint256 public constant _ONE_HUNDRED_DAYS = 8640000;
  uint256 public constant _TWENTY_FIVE_DAYS = 2160000;
  uint256 public constant _TEN_DAYS = 864000;

  //*********************************************************************//
  // --------------------- private stored properties ------------------- //
  //*********************************************************************//
  /**
    @notice
    Tracks the specs of each tokenId which are basically locked amount, lock-in duration and total lock-in period.
  */
  mapping(uint256 => uint256) private _packedSpecs;

  /** 
    @notice 
    ERC20 Token Instance
  */
  IERC20 public immutable token;

  /** 
    @notice 
    JBProject id.
  */
  uint256 public immutable projectId;

  /** 
    @notice 
    Token URI Resolver Instance
  */
  ITokenUriResolver public uriResolver;

  /** 
    @notice 
    The JBTokenStore where unclaimed tokens are accounted for.
  */
  IJBTokenStore public tokenStore;

  /** 
    @notice 
    Banny id counter
  */
  uint256 public count;

  //*********************************************************************//
  // ---------------------------- constructor -------------------------- //
  //*********************************************************************//

  /**
    @param _token Erc20 token address.
    @param _projectId The ID of the project.
    @param _name Nft name.
    @param _symbol Nft symbol.
    @param _uriResolver Token uri resolver instance.
    @param _tokenStore The JBTokenStore where unclaimed tokens are accounted for.
  */
  constructor(
    IERC20 _token,
    uint256 _projectId,
    string memory _name,
    string memory _symbol,
    ITokenUriResolver _uriResolver,
    IJBTokenStore _tokenStore
  ) ERC721(_name, _symbol) EIP712('JBveBanny', '1') {
    require(address(_tokenStore.tokenOf(_projectId)) == address(_token), 'mismatch');
    token = _token;
    projectId = _projectId;
    uriResolver = _uriResolver;
    tokenStore = _tokenStore;
  }

  /**
    @notice
    Allows token holder to lock in their tokens in exchange for a banny.
    
    @param _account ERC20 Token Token Holder.
    @param _amount Lock Amount.
    @param _duration Lock time in seconds.
    @param _beneficiary Address to mint the banny.
    @param _useErc20 A flag indicating if ERC-20 tokens are being locked. If false, unclaimed project tokens from the JBTokenStore will be locked.
  */
  function lock(
    address _account,
    uint256 _amount,
    uint48 _duration,
    address _beneficiary,
    bool _useErc20
  ) external nonReentrant {
    // Duration must match.
    if (
      _duration != _ONE_THOUSAND_DAYS &&
      _duration != _TWO_HUNDRED_FIFTY_DAYS &&
      _duration != _ONE_HUNDRED_DAYS &&
      _duration != _TWENTY_FIVE_DAYS &&
      _duration != _TEN_DAYS
    ) {
      revert INVALID_DURATION();
    }

    // Make sure the msg.sender is locking its own tokens.
    if (msg.sender != _account) {
      revert INVALID_ACCOUNT();
    }

    // Make sure the token balance of the account is enough to lock the specified _amount of tokens.
    if (_useErc20 && token.balanceOf(_account) < _amount) {
      revert INSUFFICIENT_BALANCE();
    } else if (!_useErc20 && tokenStore.unclaimedBalanceOf(_account, projectId) < _amount) {
      revert INSUFFICIENT_BALANCE();
    }

    // Increment the number of ve positions that have been minted.
    count += 1;

    // Calculate the time when this lock will end (in seconds).
    uint48 _lockedUntil = uint48(block.timestamp) + _duration;

    // Store packed specification values for the ve position.
    // _amount in the bits 0-151.
    uint256 packedValue = _amount;
    // _duration in the bits 152-199.
    packedValue |= _duration << 152;
    // _lockedUntil in the bits 200-247.
    packedValue |= _lockedUntil << 200;
    // _isErc20 in bit 248.
    if (_useErc20) packedValue |= 1 << 248;

    _packedSpecs[count] = packedValue;

    // Mint the position for the beneficiary.
    _mint(_beneficiary, count);

    if (_useErc20) {
      // Transfer the token to this contract where they'll be locked.
      // Will revert if not enough allowance.
      token.transferFrom(msg.sender, address(this), _amount);
    } else {
      // Transfer the token to this contract where they'll be locked.
      // Will revert if this contract isn't an opperator.
      tokenStore.transferTo(address(this), msg.sender, projectId, _amount);
    }

    // Emit event.
    emit Lock(_account, _amount, _duration, _beneficiary, _lockedUntil, msg.sender);
  }

  /**
    @notice
    Allows banny holders to burn their banny and get back the locked in amount.

    @param _tokenId Banny Id.
    @param _beneficiary Address to transfer the locked amount to.
  */
  function unlock(uint256 _tokenId, address _beneficiary) external nonReentrant {
    // Unpack the position specs for the probided tokenId.
    uint256 packedValue = _packedSpecs[_tokenId];
    // _amount in the bits 0-151.
    uint256 _amount = uint256(uint152(packedValue));
    // _lockedUntil in the bits 200-247.
    uint256 _lockedUntil = uint256(uint48(packedValue >> 200));
    // _isErc20 in the bit 248.
    bool _isErc20 = (packedValue >> 248) & 1 == 1;

    // The lock must have expired.
    if (block.timestamp <= _lockedUntil) {
      revert LOCK_PERIOD_NOT_OVER();
    }

    // Burn the token.
    _burn(_tokenId);

    if (_isErc20) {
      // Transfer the amount of locked tokens to beneficiary.
      token.transfer(_beneficiary, _amount);
    } else {
      // Transfer the tokens from this contract.
      tokenStore.transferTo(_beneficiary, address(this), projectId, _amount);
    }

    // Emit event.
    emit Unlock(_tokenId, _beneficiary, _amount, msg.sender);
  }

  /**
    @notice
    Allows banny holders to extend their token lock-in duration

    @param _tokenId Banny Id.
    @param _updatedDuration New lock-in duration.
  */
  function extendLock(uint256 _tokenId, uint48 _updatedDuration) external nonReentrant {
    // Duration must match.
    if (
      _updatedDuration != _ONE_THOUSAND_DAYS &&
      _updatedDuration != _TWO_HUNDRED_FIFTY_DAYS &&
      _updatedDuration != _ONE_HUNDRED_DAYS &&
      _updatedDuration != _TWENTY_FIVE_DAYS &&
      _updatedDuration != _TEN_DAYS
    ) {
      revert INVALID_DURATION();
    }

    // check is the msg.sender is the owner of the banny or not
    if (ownerOf(_tokenId) != msg.sender) {
      revert INVALID_ACCOUNT();
    }

    // fetch the stored packed value.
    uint256 packedValue = _packedSpecs[_tokenId];
    // get prev. duration value
    uint256 _duration = uint48(packedValue >> 152);
    // get prev. lockedUntil Value
    uint256 _lockedUntil = uint48(packedValue >> 200);
    // Calculate the updated time when this lock will end (in seconds).
    uint256 _updatedLockedUntil = (_lockedUntil + _updatedDuration) - _duration;
    // _duration in the bits 152-199.
    // update the value in these bits.
    packedValue |= uint48(_updatedDuration << 152);
    // _lockedUntil in the bits 200-247.
    // update the value in these bits.
    packedValue |= uint48(_updatedLockedUntil << 200);

    // update the mapping with new packed values
    _packedSpecs[_tokenId] = packedValue;
    emit ExtendLock(_tokenId, _updatedDuration, msg.sender);
  }

  /**
     @notice 
     Allows the owner to set the uri resolver.

     @param _resolver The new URI resolver.
  */
  function setUriResolver(ITokenUriResolver _resolver) external onlyOwner {
    uriResolver = _resolver;
    emit SetUriResolver(_resolver, msg.sender);
  }

  /**
     @notice 
     Computes the metadata url based on the id.

     @param _tokenId TokenId of the Banny

     @return dynamic uri based on the svg logic for that particular banny
  */
  function tokenURI(uint256 _tokenId) public view override returns (string memory) {
    // svg logic where based on user stake we render the nft
    uint256 packedValue = _packedSpecs[_tokenId];
    // _amount in the bits 0-151.
    uint256 _amount = uint256(uint152(packedValue));
    // _duration in the bits 152-199.
    uint256 _duration = uint256(uint48(packedValue >> 152));
    // _lockedUntil in the bits 200-247.
    uint256 _lockedUntil = uint256(uint48(packedValue >> 200));

    return uriResolver.tokenURI(_tokenId, _amount, _duration, _lockedUntil);
  }

  /**
    @notice
    Unpacks the packed specs of each banny based on token id.

    @param _tokenId Banny Id.

    @return amount Locked amount
    @return duration Locked duration
    @return lockedUntil Locked until this timestamp.
    @return isErc20 If the locked tokens are erc20. 
  */
  function getSpecs(uint256 _tokenId)
    external
    view
    returns (
      uint256 amount,
      uint256 duration,
      uint256 lockedUntil,
      bool isErc20
    )
  {
    uint256 _packedValue = _packedSpecs[_tokenId];
    // _amount in the bits 0-151.
    amount = uint256(uint152(_packedValue));
    // _duration in the bits 152-199.
    duration = uint256(uint48(_packedValue));
    // _lockedUntil in the bits 200-247.
    lockedUntil = uint256(uint48(_packedValue >> 200));
    // _lockedUntil in the bits 248.
    isErc20 = (_packedValue >> 248) & 1 == 1;
  }

  /**
    @notice
    Gets the amount of voting units an account has given its locked positions.

    @param _account The account to get voting units of.

    @return units The amount of voting units the account has.
   */
  function _getVotingUnits(address _account) internal view override returns (uint256 units) {
    // Loop through all positions owned by the _account.
    for (uint256 _i; _i < balanceOf(_account); _i++) {
      // Get the token represented a positioned owned by the account.
      uint256 _tokenId = tokenOfOwnerByIndex(_account, _i);
      // Unpack specs for the position.
      uint256 _packedValue = _packedSpecs[_tokenId];
      // _amount in the bits 0-151.
      uint256 _amount = uint256(uint152(_packedValue));
      // _lockedUntil in the bits 200-247.
      uint256 _lockedUntil = uint256(uint48(_packedValue >> 200));
      // Voting balance for each token is a function of how much time is left on the lock.
      units += PRBMath.mulDiv(_amount, (_lockedUntil - block.timestamp), _ONE_THOUSAND_DAYS);
    }
  }

  /**
    @dev Requires override. Calls super.
  */
  function supportsInterface(bytes4 _interfaceId)
    public
    view
    virtual
    override(ERC721, ERC721Enumerable)
    returns (bool)
  {
    return super.supportsInterface(_interfaceId);
  }

  /**
    @dev Requires override. Calls super.
  */
  function _afterTokenTransfer(
    address _from,
    address _to,
    uint256 _tokenId
  ) internal virtual override(ERC721Votes, ERC721) {
    return super._afterTokenTransfer(_from, _to, _tokenId);
  }

  /**
    @dev Requires override. Calls super.
  */
  function _beforeTokenTransfer(
    address _from,
    address _to,
    uint256 _tokenId
  ) internal virtual override(ERC721, ERC721Enumerable) {
    return super._beforeTokenTransfer(_from, _to, _tokenId);
  }
}
