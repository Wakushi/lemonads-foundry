const { ethers } = await import("npm:ethers@6.10.0")
const abiCoder = ethers.AbiCoder.defaultAbiCoder()

const timestamp = args[0]

const { data } = await Functions.makeHttpRequest({
  url: `https://lemonads.vercel.app/api/ad/clicks?timestamp=${timestamp}`,
})

const clicks = data.clicks
const clickPerParcel = new Map()

clicks.forEach(({ adParcelId }) => {
  if (clickPerParcel.has(adParcelId)) {
    clickPerParcel.set(adParcelId, clickPerParcel.get(adParcelId) + 1)
    return
  }

  clickPerParcel.set(adParcelId, 1)
})

const clicksArray = Array.from(clickPerParcel, ([name, value]) => ({
  adParcelId: Number(name),
  clicks: value,
}))

const encodedData = abiCoder.encode(
  ["tuple(uint256 adParcelId, uint256 clicks)[]"],
  [clicksArray]
)

console.log("clicksArray: ", clicksArray)
console.log(encodedData)

return ethers.getBytes(encodedData)
