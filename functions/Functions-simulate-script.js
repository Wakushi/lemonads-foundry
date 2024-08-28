const { simulateScript } = require("@chainlink/functions-toolkit")
const requestConfig = require("./Functions-request-config")

async function main() {
  const { responseBytesHexstring, capturedTerminalOutput, errorString } =
    await simulateScript(requestConfig)
  console.log("bytes response:", responseBytesHexstring)
  console.log("error: ", errorString)
  console.log("Output: ", capturedTerminalOutput)
}

main()
