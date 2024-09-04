const { ethers } = await import("npm:ethers@6.10.0")
const abiCoder = ethers.AbiCoder.defaultAbiCoder()

if (!secrets.SECRET_KEY) {
  throw Error("Secret key required")
}

await Functions.makeHttpRequest({
  url: `https://lemonads.vercel.app/api/ping`,
})

const uuid = args.splice(args.length - 1, 1)[0]

const apiResponse = await Functions.makeHttpRequest({
  url: "https://lemonads.vercel.app/api/notifications",
  method: "POST",
  headers: {
    Authorization: `Bearer ${secrets.SECRET_KEY}`,
    "Content-Type": "application/json",
  },
  data: {
    uuid,
    notificationList: args,
  },
})

if (apiResponse.error) {
  throw Error("Request failed")
}

const { data } = apiResponse
return Functions.encodeString(data.accepted)
