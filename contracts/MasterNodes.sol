// SPDX-License-Identifier: MIT
pragma solidity 0.8.17;

import "./EnumerableSet.sol";
import "./TransferHelper.sol";
import "./Ownable.sol";

interface ISimplifiedGlobalFarm {
    function mintFarmingReward(address _localFarm) external;
    function getAllocationX1000(address _farm) external view returns (uint256);
    function getRewardPerSecond() external view returns (uint256);
    function getlastPayment(address _localFarmAddress) external view returns (uint256);
    function next_payment() external view returns (uint256);
    function rewardMintingAvailable(address _farm) external view returns (bool);
    function farmExists(address _farmAddress) external view returns (bool);
    function owner() external view returns (address);
}

interface IERC20 {
    function balanceOf(address who) external view returns (uint256);
}

contract MasterNodes is Ownable {
    using EnumerableSet for EnumerableSet.AddressSet;
    using TransferHelper for address;
    //EnumerableSet.AddressSet _userNodes; // Enumerable list of users authority addresses (should be different then Node owner wallet)
    //EnumerableSet.AddressSet _callistoNodes; // Enumerable list of Callisto Enterprise authority addresses(should be different then Node owner wallet)

    // BEGIN MAIN NET VALUES
    address constant public SOY_TOKEN = 0x9FaE2529863bD691B4A7171bDfCf33C7ebB10a65;
    address constant public CLOE_TOKEN = 0x1eAa43544dAa399b87EEcFcC6Fa579D5ea4A6187;
    address constant public globalFarm = 0x64Fa36ACD0d13472FD786B03afC9C52aD5FCf023;
    // minimum and maximum deposit amount
    uint256 constant public minCLO  = 500000 ether;
    uint256 constant public maxCLO  = 5000000 ether;
    uint256 constant public minCLOE = 150000 ether;
    uint256 constant public maxCLOE = 1500000 ether;
    uint256 constant public minSOY  = 25000 ether;
    uint256 constant public maxSOY  = 250000 ether;
    uint256 constant public inactiveUnlockTime = 14 days;
    // END MAIN NET VALUES

    /*
    // BEGIN TEST NET VALUES
    address constant public SOY_TOKEN = 0x4c20231BCc5dB8D805DB9197C84c8BA8287CbA92;
    address constant public CLOE_TOKEN = 0x3364AD23385E2e71756C4bb29B5E3480f312B368;
    address constant public globalFarm = 0x9F66541abc036503Ae074E1E28638b0Cb6165458;

    // minimum and maximum deposit amount
    uint256 constant public minCLO  = 5 ether;
    uint256 constant public maxCLO  = 50 ether;
    uint256 constant public minCLOE = 15 ether;
    uint256 constant public maxCLOE = 150 ether;
    uint256 constant public minSOY  = 25 ether;
    uint256 constant public maxSOY  = 250 ether;
    uint256 constant public inactiveUnlockTime = 1 hours;
    // END TEST NET VALUES
    */
    
    // part of total reward (%) to split among master nodes belong to users
    uint256 public usersNodesRewardRatio; 
    // Maximum number of nodes belong to users
    //uint256 public maxUserNodes;
    //uint256 public userInactiveNodes;
    // Maximum number of nodes belong to Callisto Enterprise
    //uint256 public maxCallistoNodes;
    //uint256 public callistoInactiveNodes;
    // Total deposited
    //uint256[3] public userDeposits;    // 0 - CLO, 1 - CLOE, 2 - SOY
    // Callisto Enterprise nodes deposits
    //uint256[3] public callistoDeposits;    // 0 - CLO, 1 - CLOE, 2 - SOY
    // reward ratio of 100
    uint256[3] public ratio;   // percent of total rewards per token type (0 - CLO, 1 - CLOE, 2 - SOY)
    uint256[3] public accumulatedRewardPerShare; // 0 - CLO, 1 - CLOE, 2 - SOY
    uint256 public lastRewardTimestamp;

    struct Details {
        EnumerableSet.AddressSet nodes; //list of authority addresses (should be different then Node owner wallet)
        uint256 maxNodes;
        uint256 inactiveNodes;
        uint256[3] totalDeposits;   // 0 - CLO, 1 - CLOE, 2 - SOY
    }

    struct Node {
        address owner;  //  address of master node owner
        bool isActive;
        uint8 isUser;   // master node can belong to users or to Callisto Enterprise (CE)
        uint256[3] balances;    //0 - CLO, 1 - CLOE, 2 - SOY
        uint256[3] rewardPerShares;    //0 - CLO, 1 - CLOE, 2 - SOY
        uint256 unlockTime; // time when user can withdraw collaterals if node isn't active
        string url; // authority URL
    }
    
    Details[2] private _details; // 0 - Callisto Enterprise nodes, 1 - users nodes
    mapping(address => Node) private _nodes; // nodes
    mapping(address => address) public authorityByOwner;   // address(0) - empty, address(1) - belong to Callisto Enterprise, otherwise address of authority
    uint256 public pendingCallistoReward;

    event SetRatios(uint256 _ratioCLO, uint256 _ratioCLOE, uint256 _ratioSOY, uint256 _usersNodesRewardRatio);
    event NodeAdded(address indexed authority, Node node);
    event TokensAdded(address indexed authority, Node node);
    event NodeActivated(address indexed authority);
    event NodeDeactivated(address indexed authority);
    event NodeRemoved(address indexed authority);
    event RewardAdded(uint256 reward);
    event RescueERC20(address token, address to, uint256 value);

    function initialize() external {
        require(_owner == address(0), "Already initialized");
        _owner = msg.sender;
        emit OwnershipTransferred(address(0), msg.sender);
        ratio[0] = 62;  // CLO ratio 62%
        ratio[1] = 27;  // CLOE ratio 27%
        ratio[2] = 11;  // SOY ratio 11%
        usersNodesRewardRatio = 65; // rewards will be split by 65% to master nodes held by users and 35% to master nodes held by Callisto Enterprise
        emit SetRatios(ratio[0],ratio[1], ratio[2], usersNodesRewardRatio);
        _details[0].maxNodes = 11; // 11 nodes may belong to Callisto Enterprise
        _details[1].maxNodes = 10; // 10 nodes may belong to users
    }

    // add master node. If msg.sender is admin, then node belong to Callisto Enterprise otherwise node belong to user
    function addNode(uint256 amountCLOE, uint256 amountSOY, address authority, string calldata url) external payable {
        _checkAmounts(msg.value, amountCLOE, amountSOY);
        uint256 isUser;
        // If added by contract owner then it's Callisto Enterprise node. 
        // All Callisto Enterprise nodes belong to contract owner
        if (owner() != msg.sender) { // user node
            require(authorityByOwner[msg.sender] == address(0), "User already has node");
            require(_nodes[authority].owner == address(0), "authority already added");
            isUser = 1;
            authorityByOwner[msg.sender] = authority;
        }
        require(_details[isUser].nodes.length() < _details[isUser].maxNodes, "All nodes added");
        require(_details[isUser].nodes.contains(authority) == false, "Authority already added");
        _details[isUser].inactiveNodes++;

        CLOE_TOKEN.safeTransferFrom(msg.sender, address(this), amountCLOE);
        SOY_TOKEN.safeTransferFrom(msg.sender, address(this), amountSOY);

        Node memory _node = Node({
            owner: msg.sender,
            isActive: false,
            isUser: uint8(isUser),
            balances: [msg.value, amountCLOE, amountSOY],
            rewardPerShares: [uint256(0), 0, 0],
            unlockTime: block.timestamp + inactiveUnlockTime,
            url: url
        });

        _nodes[authority] = _node;
        emit NodeAdded(authority, _node);

        if(isUser == 0) activateNode(authority);    // automatically active Callisto Enterprise node
    }

    // add more tokens to active user's master node
    function addTokens(uint256 amountCLOE, uint256 amountSOY) external payable {
        update();
        _payRewards(msg.sender);
        address authority = authorityByOwner[msg.sender];
        Node storage n = _nodes[authority];
        require(authority != address(0) && n.isUser == 1, "Only user's node");
        require(n.isActive, "Not active");
        _checkAmounts(msg.value + n.balances[0], amountCLOE + n.balances[1], amountSOY + n.balances[2]);
        CLOE_TOKEN.safeTransferFrom(msg.sender, address(this), amountCLOE);
        SOY_TOKEN.safeTransferFrom(msg.sender, address(this), amountSOY);
        // update user's balances
        n.balances[0] += msg.value;
        n.balances[1] += amountCLOE;
        n.balances[2] += amountSOY;
        // update total deposits
        _details[1].totalDeposits[0] += msg.value;
        _details[1].totalDeposits[1] += amountCLOE;
        _details[1].totalDeposits[2] += amountSOY;
        emit TokensAdded(authority, n);
    }

    // activate node (authority)
    function activateNode (address authority) public onlyOwner{
        update();
        Node storage n = _nodes[authority];
        require(n.owner != address(0) && !n.isActive, "wrong authority");
        uint256 isUser = uint256(n.isUser);
        require(_details[isUser].nodes.length() < _details[isUser].maxNodes, "All nodes added");
        require(_details[isUser].nodes.add(authority), "Authority already added");
        _details[isUser].inactiveNodes--;
        // update total deposits
        _details[isUser].totalDeposits[0] += n.balances[0];
        _details[isUser].totalDeposits[1] += n.balances[1];
        _details[isUser].totalDeposits[2] += n.balances[2];
        if (isUser == 1) n.rewardPerShares = accumulatedRewardPerShare; // save rewardPerShares only for users node
        n.isActive = true;
        emit NodeActivated(authority);
    }

    // deactivate node (authority)
    function deactivateNode (address authority) external {
        update();
        Node storage n = _nodes[authority];
        require(n.owner != address(0) && n.isActive, "wrong authority");
        require(n.owner == msg.sender || owner() == msg.sender, "Only node or contract owner");
        uint256 isUser = uint256(n.isUser);
        require(_details[isUser].nodes.remove(authority), "Authority not exist");
        _details[isUser].inactiveNodes++;
        // update total deposits
        _details[isUser].totalDeposits[0] -= n.balances[0];
        _details[isUser].totalDeposits[1] -= n.balances[1];
        _details[isUser].totalDeposits[2] -= n.balances[2];
        n.isActive = false;
        n.unlockTime = block.timestamp + inactiveUnlockTime;
        if (isUser == 1) _payRewards(n.owner);
        else _payRewards(owner());
        emit NodeDeactivated(authority);
    }

    // remove deactivated node (authority) and receive collateral  (allowed after unlock period)
    function removeNode (address authority) external {
        update();
        Node storage n = _nodes[authority];
        address nodeOwner = n.owner;
        require(nodeOwner != address(0) && !n.isActive, "wrong authority");
        require(nodeOwner == msg.sender || owner() == msg.sender, "Only node or contract owner");
        require(n.unlockTime <= block.timestamp, "Node is locked");
        _details[uint(n.isUser)].inactiveNodes--; // remove node from inactive counter
        uint256 amountCLO = n.balances[0];
        uint256 amountCLOE = n.balances[1];
        uint256 amountSOY = n.balances[2];
        delete _nodes[authority];
        delete authorityByOwner[nodeOwner];
        nodeOwner.safeTransferETH(amountCLO);
        CLOE_TOKEN.safeTransfer(nodeOwner, amountCLOE);
        SOY_TOKEN.safeTransfer(nodeOwner, amountSOY);
        emit NodeRemoved(authority);
    }

    // claim earned reward
    function claimReward() external {
        update();
        _payRewards(msg.sender);
    }

    function _payRewards(address user) internal {
        uint256 reward;
        address authority = authorityByOwner[user];
        if (authority != address(0)) {  // user's node
            Node storage n = _nodes[authority];
            if (n.isActive) {   // reward available only for active nodes
                for (uint256 i = 0; i < 3; i++) {
                    reward = reward + (n.balances[i] * (accumulatedRewardPerShare[i] - n.rewardPerShares[i]) / 1e18);
                }
                n.rewardPerShares = accumulatedRewardPerShare; // save rewardPerShares only for users node
            }
        } else if (user == owner() && _details[0].nodes.length() != 0) {   // callisto's node
            // contract owner receive reward from all nodes belong to Callisto Enterprise
            reward = pendingCallistoReward;
            pendingCallistoReward = 0;
        }
        if (reward != 0) SOY_TOKEN.safeTransfer(user, reward);
    }

    function _checkAmounts(uint256 amountCLO, uint256 amountCLOE,uint256 amountSOY) internal pure {
        require(amountCLO >= minCLO, "Not enough CLO");
        require(amountCLOE >= minCLOE, "Not enough CLOE");
        require(amountSOY >= minSOY, "Not enough SOY");
        require(amountCLO <= maxCLO, "Too many CLO"); 
        require(amountCLOE <= maxCLOE, "Too many CLOE"); 
        require(amountSOY <= maxSOY, "Too many SOY"); 
    }

    // get master node info by authority address
    function getNodeByAuthority(address authority) public view returns (Node memory) {
        return _nodes[authority];
    }

    // get user's master node info by owner address
    function getUsersNodeByOwner(address owner) external view returns (Node memory node, address authority) {
        authority = authorityByOwner[owner];
        node = _nodes[authority];
    }

    // get all Callisto Enterprise nodes
    function getCallistoNodes() external view returns(Node[] memory nodes, address[] memory authorities) {
        uint256 nodeLength = _details[0].nodes.length();
        authorities = new address[](nodeLength);
        nodes = new Node[](nodeLength);
        for (uint i = 0; i < nodeLength; i++) {
            authorities[i] = _details[0].nodes.at(i);
            nodes[i] = _nodes[authorities[i]];
        }
    }

    // get master node info by Id, belongUsers = 1 if get node that belong to users
    function getNodeById(uint256 id, bool belongUsers) external view returns (Node memory node, address authority) {
        if (belongUsers) authority = _details[1].nodes.at(id);
        else authority = _details[0].nodes.at(id);
        node = _nodes[authority];
    }

    // get number of nodes belong to Callisto Enterprise and users
    function getNumberOfNodes() external view returns (uint256 callistoNodes, uint256 usersNodes) {
        callistoNodes = _details[0].nodes.length();
        usersNodes = _details[1].nodes.length();
    }

    // get details (deposits). id = 0 for callisto nodes, 1 for users nodes
    function getDetails(uint256 id) external view returns(uint256 maxNodes, uint256 inactiveNodes, uint256[3] memory totalDeposits) {
        maxNodes = _details[id].maxNodes;
        inactiveNodes = _details[id].inactiveNodes;
        totalDeposits = _details[id].totalDeposits; 
    }

    // Set reward ratios
    function setRatios(uint256 _ratioCLOE, uint256 _ratioSOY, uint256 _usersNodesRewardRatio) external onlyOwner {
        require(_ratioCLOE + _ratioSOY <= 100, "Total ratio > 100%");
        ratio[0] = 100 - _ratioCLOE - _ratioSOY;    // CLO ratio
        ratio[1] = _ratioCLOE;
        ratio[2] = _ratioSOY;
        require(_usersNodesRewardRatio <= 100, "Users ratio > 100%");
        usersNodesRewardRatio = _usersNodesRewardRatio;
        emit SetRatios(ratio[0], _ratioCLOE, _ratioSOY, _usersNodesRewardRatio);
    }

    // farming functions
    function notifyRewardAmount(uint256 reward) external {
        require(msg.sender == globalFarm, "Only globalFarm");
        if (lastRewardTimestamp == 0) {
            lastRewardTimestamp = block.timestamp;
        }
        emit RewardAdded(reward);
    }
    
    function getRewardPerSecond() public view returns (uint256)
    {
        return ISimplifiedGlobalFarm(globalFarm).getRewardPerSecond();
    }
    
    function getAllocationX1000() public view returns (uint256)
    {
        return ISimplifiedGlobalFarm(globalFarm).getAllocationX1000(address(this));
    }

    // get earned reward 
    function getReward(address user) public view returns(uint256 reward) {
        address authority = authorityByOwner[user];
        uint256 _reward = (block.timestamp - lastRewardTimestamp) * getRewardPerSecond() * getAllocationX1000() / 1000;
        if (authority != address(0)) {  // user's node
            Node storage n = _nodes[authority];
            if (n.isActive) {   // reward available only for active nodes
                _reward = _reward * usersNodesRewardRatio / 100;
                for (uint256 i = 0; i < 3; i++) {
                    uint256 r = _reward * ratio[i] / 100;
                    uint256 acc = accumulatedRewardPerShare[i] + (r * 1e18 / _details[1].totalDeposits[i]);
                    reward = reward + (n.balances[i] * (acc - n.rewardPerShares[i]) / 1e18);
                }
            }
        } else if (user == owner() && _details[0].nodes.length() != 0) {   // callisto's node
            // contract owner receive reward from all nodes belong to Callisto Enterprise
            reward = pendingCallistoReward + (_reward * (100 - usersNodesRewardRatio) / 100);
        }
    }

    // Update reward variables of this Local Farm to be up-to-date.
    function update() public {
        ISimplifiedGlobalFarm(globalFarm).mintFarmingReward(address(this));

        if (block.timestamp <= lastRewardTimestamp) {
            return;
        }

        if (lastRewardTimestamp == 0) return; // start calculate reward from first minting

        uint256 multiplier = block.timestamp - lastRewardTimestamp;
        uint256 _totalReward = multiplier * getRewardPerSecond() * getAllocationX1000() / 1000;
        uint256 _reward = _totalReward * usersNodesRewardRatio / 100;  // users' part of rewards
        pendingCallistoReward = pendingCallistoReward + (_totalReward - _reward);   // callisto's part of rewards
        for (uint256 i = 0; i < 3; i++) {
            uint256 r = _reward * ratio[i] / 100; // part of reward per token type
            uint256 deposit = _details[1].totalDeposits[i];
            if (deposit != 0)
                accumulatedRewardPerShare[i] = accumulatedRewardPerShare[i] + (r * 1e18 / deposit);
        }
        lastRewardTimestamp = block.timestamp;
    }

    // Rescue ERC20 tokens
    function rescueERC20(address token, address to) external onlyOwner {
        uint256 value = IERC20(token).balanceOf(address(this));
        if (token == CLOE_TOKEN) {
            value = value - _details[0].totalDeposits[1] - _details[1].totalDeposits[1];
        } else if (token == SOY_TOKEN) {
            require(
                _details[0].totalDeposits[2] == 0 && _details[1].totalDeposits[2] == 0, 
                "SOY in use"
            ); // allow rescue SOY token only if there is not SOY deposits
        }
        token.safeTransfer(to, value);
        emit RescueERC20(token, to, value);
    }
}
