import { GoogleGenerativeAI } from "@google/generative-ai";
import { GoogleAIFileManager, FileState } from "@google/generative-ai/server";

const API_KEY = "AIzaSyCH_xqKwyNQ3nUJO4i8lH2Asyfm7Bbh408";

// 1. Initialize two separate managers
const fileManager = new GoogleAIFileManager(API_KEY);
const genAI = new GoogleGenerativeAI(API_KEY);

async function processPdfToJson(filePath: string): Promise<void> {
  try {
    console.log("Uploading file...");

    // 2. Upload using fileManager (Accepts local path directly)
    const uploadResponse = await fileManager.uploadFile(filePath, {
      mimeType: "application/pdf",
      displayName: "DocumentAnalysis",
    });

    const fileName = uploadResponse.file.name;
    const fileUri = uploadResponse.file.uri;

    // 3. Poll for processing state
    let file = await fileManager.getFile(fileName);
    while (file.state === FileState.PROCESSING) {
      process.stdout.write(".");
      await new Promise<void>((resolve) => setTimeout(resolve, 2000));
      file = await fileManager.getFile(fileName);
    }

    if (file.state === FileState.FAILED) throw new Error("File processing failed.");
    console.log("\nFile ready for analysis.");

    // 4. Get the model instance
    const model = genAI.getGenerativeModel({ 
        model: "gemini-2.5-flash-lite" // Recommended; check availability of 2.5 in your region
    });

    const prompt = "Extract all key data points from this PDF and return them in a structured JSON format.";

    // 5. Correct generation syntax
    const result = await model.generateContent([
      {
        fileData: {
          mimeType: "application/pdf",
          fileUri: fileUri,
        },
      },
      { text: prompt },
    ]);

    // 6. Output result
    const text = result.response.text();
    if (!text) throw new Error("Empty response from model");

    // Clean markdown code blocks if they exist, then parse
    const cleanJson = text.replace(/```json|```/g, "").trim();
    const jsonOutput = JSON.parse(cleanJson);
    
    console.log("--- Extracted Data ---");
    console.log(JSON.stringify(jsonOutput, null, 2));

  } catch (error) {
    console.error(
      "Error:",
      error instanceof Error ? error.message : String(error)
    );
  }
}

processPdfToJson(
  "/Users/welcome/Documents/other/statements/AcctStatement_XXX7918_12042026 (1).pdf"
);