// SPDX-License-Identifier: MIT
pragma solidity =0.5.17;

contract WBKC {
    string public name = "Wrapped BKC";
    string public symbol = "WBKC";
    uint8 public decimals = 18;
    bool private locked;

    event Approval(address indexed src, address indexed guy, uint wad);
    event Transfer(address indexed src, address indexed dst, uint wad);
    event Deposit(address indexed dst, uint wad);
    event Withdrawal(address indexed src, uint wad);

    mapping(address => uint) public balanceOf;
    mapping(address => mapping(address => uint)) public allowance;

    modifier noReentrant() {
        require(!locked, "ReentrancyGuard: reentrant call");
        locked = true;
        _;
        locked = false;
    }

    function() external payable {
        deposit();
    }
    function deposit() public payable {
        balanceOf[msg.sender] += msg.value;
        emit Deposit(msg.sender, msg.value);
    }
    function withdraw(uint wad) public {
        require(balanceOf[msg.sender] >= wad);
        balanceOf[msg.sender] -= wad;
        msg.sender.transfer(wad);
        emit Withdrawal(msg.sender, wad);
    }

    function totalSupply() public view returns (uint) {
        return address(this).balance;
    }

    function approve(address guy, uint wad) public returns (bool) {
        allowance[msg.sender][guy] = wad;
        emit Approval(msg.sender, guy, wad);
        return true;
    }

     function transfer(address dst, uint wad) public returns (bool) {
      require(dst != address(0), "Invalid destination address");
      if (dst == address(this)) {
          return _redeem(msg.sender, wad);
      }
      return transferFrom(msg.sender, dst, wad);
    }


   function _redeem(address from, uint wad) internal noReentrant returns (bool) {
    require(balanceOf[from] >= wad, "insufficient WBKC");
    require(address(this).balance >= wad, "insufficient BKC liquidity");

    // 转账
    balanceOf[from] -= wad;

    // 赎回BKC
    address(uint160(from)).transfer(wad);


    emit Transfer(from, address(0), wad);
    emit Withdrawal(from, wad);

    return true;
}

    function transferFrom(
        address src,
        address dst,
        uint wad
    ) public returns (bool) {
        require(balanceOf[src] >= wad);

        if (src != msg.sender && allowance[src][msg.sender] != uint(-1)) {
            require(allowance[src][msg.sender] >= wad);
            allowance[src][msg.sender] -= wad;
        }

        balanceOf[src] -= wad;
        balanceOf[dst] += wad;

        emit Transfer(src, dst, wad);

        return true;
    }
}
