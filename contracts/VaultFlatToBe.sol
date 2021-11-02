// SPDX-License-Identifier: MIT
pragma solidity 0.8.0;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";

contract Vault is Ownable {
    using SafeERC20 for IERC20;
    using SafeMath for uint256;

    uint256 public taxForNonBabyDogeCoin;
    IERC20 public babydoge;

    struct UserInfo {
        uint256 amount;
        uint256 weight;
        uint256 rewardTotal;
        uint256 rewardWithdraw;
        uint256 lockTime;
        uint256 lockDays;
        uint256 lastRewardDay;
        bool exists;
    }
    mapping(uint256 => mapping(address => UserInfo)) public userInfo;
    mapping(uint256 => uint256) public vaultKeys;

    struct TotalDay {
        uint256 amount;
        uint256 weight;
    }
    mapping(uint256 => mapping(uint256 => TotalDay)) public totalDay;

    struct VaultToken {
        IERC20 tokenStake;
        IERC20 tokenReward;
        address vaultCreator;
    }

    struct VaultInfo {
        uint256 amountReward;
        uint256 vaultTokenTax;
        uint256 startVault;
        uint256 vaultDays;
        uint256 minLockDays;
        uint256 userCount;
        uint256 usersAmount;
        uint256 usersWeight;
        bool isLpVault;
        bool paused;
        uint256 lastTotalDay;
    }
    VaultToken[] public vaultToken;
    VaultInfo[] public vaultInfo;

    event Deposit(address indexed user, uint256 indexed pid, uint256 amount);
    event Withdraw(address indexed user, uint256 indexed pid, uint256 amount);

    constructor() {
        babydoge = IERC20(0x355EB8acCbe34bB8B636B7B530Ffe9e16bd956E0);
    }

    function setTaxForNonBabyDogeCoin(uint256 _taxForNonBabyDogeCoin) public onlyOwner {
        taxForNonBabyDogeCoin = _taxForNonBabyDogeCoin;
    }

    //0x355EB8acCbe34bB8B636B7B530Ffe9e16bd956E0 - babydoge
    //0xA41B55aC5689712735F4FA754946BeF09deF59da - no fee token
    function createVault(
        uint256 key,
        IERC20 _tokenStake,
        IERC20 _tokenReward,
        bool _isLp,
        uint256 _vaultDays,
        uint256 _minLockDays,
        uint256 _amount
    ) public returns (uint256) {
        require(vaultKeys[key] == 0, "Vault Key Already used");
        require(
            _tokenStake.balanceOf(msg.sender) >= _amount,
            "User has no tokens"
        );
        require(_vaultDays > 0, "Vault days zero");
        require(
            _minLockDays <= _vaultDays,
            "Minimum lock days greater then Vault days"
        );

        uint256 tax = 0;
        if (!isBabyDoge(_tokenReward)) {
            tax = taxForNonBabyDogeCoin;
        }
        uint256 _amountReserve = (_amount / 100) * (100 - tax);
        uint256 _tax = (_amount / 100) * tax;

        vaultToken.push(
            VaultToken({tokenStake: _tokenStake, tokenReward: _tokenReward, vaultCreator: msg.sender})
        );

        VaultInfo memory vault = VaultInfo({
            amountReward: _amountReserve,
            vaultTokenTax: _tax,
            startVault: block.timestamp,
            vaultDays: _vaultDays,
            minLockDays: _minLockDays,
            userCount: 0,
            usersAmount: 0,
            usersWeight: 0,
            isLpVault: _isLp,
            paused: false,
            lastTotalDay: block.timestamp.div(1 days).sub(1)
        });

        vaultInfo.push(vault);

        uint256 vaultId = vaultInfo.length - 1;

        vaultKeys[key] = vaultId;

        uint256 _today = today();
        TotalDay storage _totalDay = totalDay[vaultId][_today];
        _totalDay.amount = 0;
        require(
            _tokenReward.transferFrom(
                address(msg.sender),
                address(this),
                _amount
            ),
            "Can't transfer tokens."
        );

        return vaultId;
    }

    function getVaultId(uint256 key) public view returns (uint256) {
        return vaultKeys[key];
    }

    function isBabyDoge(IERC20 _token) internal view returns (bool) {
        return address(_token) == address(babydoge);
    }

    function getUserInfo(uint256 _vid, address _user)
        public
        view
        returns (
            uint256,
            uint256,
            uint256,
            uint256,
            uint256
        )
    {
        UserInfo memory user = userInfo[_vid][_user];
        return (
            user.amount,
            user.weight,
            user.rewardTotal,
            user.rewardWithdraw,
            user.lockTime
        );
    }

    function getVaultToken(uint256 _vid) public view returns (IERC20, IERC20) {
        VaultToken memory vaultT = vaultToken[_vid];
        return (vaultT.tokenStake, vaultT.tokenReward);
    }

    function getVaultInfo(uint256 _vid)
        public
        view
        returns (
            uint256,
            uint256,
            uint256,
            uint256,
            uint256,
            uint256
        )
    {
        VaultInfo memory vault = vaultInfo[_vid];
        return (
            vault.amountReward,
            vault.vaultTokenTax,
            vault.vaultDays,
            vault.minLockDays,
            vault.startVault,
            endVaultDay(_vid)
        );
    }

    function endVaultDay(uint256 _vid) internal view returns (uint256) {
        VaultInfo memory vault = vaultInfo[_vid];
        return vault.startVault.add(vault.vaultDays * 24 * 60 * 60);
    }

    function today() internal view returns (uint256) {
        return block.timestamp.div(1 days);
    }

    function yestarday(uint256 _vid) internal view returns (uint256) {
        uint256 endVault = endVaultDay(_vid);
        return
            block.timestamp > endVault
                ? endVault.div(1 days).sub(1)
                : block.timestamp.div(1 days).sub(1);
    }

    function syncDays(uint256 _vid) internal {
        VaultInfo memory vault = vaultInfo[_vid];
        uint256 _yesterday = yestarday(_vid);
        uint256 _today = today();
        //Return if already sync
        if (vault.lastTotalDay >= _yesterday) {
            return;
        }

        TotalDay memory _lastTotalDay = totalDay[_vid][vault.lastTotalDay];
        //Sync days without movements
        for (uint256 d = vault.lastTotalDay + 1; d < _today; d += 1) {
            TotalDay storage _totalDay = totalDay[_vid][d];
            _totalDay.amount = _lastTotalDay.amount;
            _totalDay.weight = _lastTotalDay.weight;
        }
    }

    function deposit(
        uint256 _vid,
        uint256 _lockDays,
        uint256 value
    ) external returns (bool) {
        require(value > 0, "Deposit must be greater than zero");
        VaultInfo storage vault = vaultInfo[_vid];
        VaultToken memory vaultT = vaultToken[_vid];
        uint256 endVault = endVaultDay(_vid);
        require(vault.paused == false, "Vault paused");
        require(block.timestamp >= vault.startVault, "Vault not started");
        require(block.timestamp <= endVault, "Vault finiched");
        require(_lockDays >= vault.minLockDays, "Locked days of the user is less than minimum lock day's Vault");
        require(
            vaultT.tokenStake.transferFrom(
                address(msg.sender),
                address(this),
                value
            )
        );
        uint256 _today = today();

        UserInfo storage user = userInfo[_vid][msg.sender];
        uint256 stakeWeight = 0;
        if (!user.exists) {
            user.exists = true;
            uint256 _lockTime = block.timestamp.add(_lockDays * 24 * 60 * 60);
            _lockTime = _lockTime > endVault ? endVault : _lockTime;
            user.lockTime = _lockTime;
            user.lockDays = _lockDays;
            user.lastRewardDay = _today;
            vault.userCount += 1;
            stakeWeight = (user.lockDays.mul(1e9)).div(vault.vaultDays).add(
                1e9
            );
            user.weight = stakeWeight;
        } else {
            //New deposits of the same user with the same weight as the first one
            stakeWeight = 0;
        }

        user.amount += value;

        syncDays(_vid);

        vault.lastTotalDay = _today;
        vault.usersAmount += value;
        vault.usersWeight += stakeWeight;

        TotalDay storage _totalDay = totalDay[_vid][_today];
        _totalDay.amount = vault.usersAmount;
        _totalDay.weight = vault.usersWeight;

        return true;
    }

    function claimRewards(uint256 _vid) public {
        VaultToken memory vaultT = vaultToken[_vid];
        VaultInfo memory vault = vaultInfo[_vid];
        require(vault.paused == false, "Vault paused");
        UserInfo storage user = userInfo[_vid][msg.sender];

        syncDays(_vid);

        uint256 _today = today();

        uint256 userReward = calcRewardsUser(_vid, msg.sender);

        user.lastRewardDay = _today;
        user.rewardTotal += userReward;
        uint256 remainingReward = user.rewardTotal.sub(user.rewardWithdraw);

        require(remainingReward > 0, "No value to claim");

        require(
            vaultT.tokenReward.transfer(address(msg.sender), remainingReward)
        );

        user.rewardWithdraw += remainingReward;
    }

    function withdraw(uint256 _vid) public {
        VaultInfo storage vault = vaultInfo[_vid];
        VaultToken memory vaultT = vaultToken[_vid];
        require(vault.paused == false, "Vault paused");
        UserInfo storage user = userInfo[_vid][msg.sender];
        require(user.lockTime <= block.timestamp, "User in lock time");

        syncDays(_vid);

        uint256 _today = today();

        uint256 userReward = calcRewardsUser(_vid, msg.sender);

        user.lastRewardDay = _today;
        user.rewardTotal += userReward;
        uint256 remainingReward = user.rewardTotal.sub(user.rewardWithdraw);

        require(vaultT.tokenStake.transfer(address(msg.sender), user.amount));
        require(
            vaultT.tokenReward.transfer(address(msg.sender), remainingReward)
        );

        user.rewardWithdraw += remainingReward;
        user.exists = false;

        vault.userCount = vault.userCount - 1;
        vault.usersAmount -= user.amount;
        vault.usersWeight -= user.weight;
        vault.lastTotalDay = user.lastRewardDay;

        TotalDay storage _totalDay = totalDay[_vid][_today];
        _totalDay.amount = vault.usersAmount;
        _totalDay.weight = vault.usersWeight;

        user.amount = 0;
        user.weight = 0;
    }

    function withdrawTax(uint256 _vid) public onlyOwner {
        VaultInfo storage vault = vaultInfo[_vid];
        VaultToken memory vaultT = vaultToken[_vid];
        require(vault.vaultTokenTax > 0, "Vault without token tax left");
        require(
            vaultT.tokenReward.transfer(owner(), vault.vaultTokenTax),
            "Can't transfer tax to owner"
        );
        vault.vaultTokenTax = 0;
    }

    function calcRewardsUser(uint256 _vid, address _user)
        public
        view
        returns (uint256)
    {
        UserInfo memory user = userInfo[_vid][_user];
        VaultInfo memory vault = vaultInfo[_vid];
        uint256 _yesterday = yestarday(_vid);
        uint256 reward = 0;
        uint256 rewardDay = vault.amountReward.div(vault.vaultDays);
        uint256 weightedAverage = 0;
        uint256 userWeight = user.weight;
        for (uint256 d = user.lastRewardDay; d <= _yesterday; d += 1) {
            TotalDay memory _totalDay = totalDay[_vid][d];
            if (_totalDay.weight > 0) {
                weightedAverage = _totalDay.amount.div(_totalDay.weight);
                reward += rewardDay
                    .mul(
                        weightedAverage.mul(userWeight).mul(1e9).div(
                            _totalDay.amount
                        )
                    )
                    .div(1e9);
            }
        }
        return reward;
    }
}