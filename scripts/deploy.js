const { ethers } = require("hardhat");

async function main() {
  // Deploying
  const contract = await ethers.getContractFactory('CBond');
  const instance = await contract.deploy();
  //const instance = await contract.deploy('0xCd538bE39Faa602F50c07B48646013E97062bCb9', '21600', '1656793800');
  await instance.deployed();
  console.log(instance.address);

  // Upgrading
  //const BoxV2 = await ethers.getContractFactory("BoxV2");
  //const upgraded = await upgrades.upgradeProxy(instance.address, BoxV2);
}

main();