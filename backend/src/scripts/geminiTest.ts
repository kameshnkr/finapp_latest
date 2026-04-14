import { GoogleGenAI, createPartFromUri } from "@google/genai";
import fs from "fs";

const API_KEY = "AIzaSyCH_xqKwyNQ3nUJO4i8lH2Asyfm7Bbh408";
const ai = new GoogleGenAI({ apiKey: API_KEY });

async function processPdfToJson(filePath: string): Promise<void> {
  try {
    // 1. Upload the PDF via the File API (Blob required for Node)
    console.log("Uploading file...");
    const fileData = fs.readFileSync(filePath);
    const blob = new Blob([fileData], { type: "application/pdf" });

    const uploadResponse = await ai.files.upload({
      file: blob,
      config: {
        displayName: "DocumentAnalysis",
        mimeType: "application/pdf",
      },
    });

    const fileName = uploadResponse.name;
    const fileUri = uploadResponse.uri;
    if (!fileName || !fileUri) {
      throw new Error("Upload failed: missing file name or URI in response");
    }

    // 2. Wait for the file to be processed
    let file = await ai.files.get({ name: fileName });
    while (file.state === "PROCESSING") {
      process.stdout.write(".");
      await new Promise<void>((resolve) => setTimeout(resolve, 2000));
      file = await ai.files.get({ name: fileName });
    }

    if (file.state === "FAILED") throw new Error("File processing failed.");
    console.log("\nFile ready for analysis.");

    // 3. Generate content — note: genAI.models.generateContent(), NOT models.get()
    const prompt =
      "Extract all key data points from this PDF and return them in a structured JSON format.";

    const result = await ai.models.generateContent({
      model: "gemini-2.5-flash-lite",
      contents: [
        {
          role: "user",
          parts: [
            createPartFromUri(fileUri, "application/pdf"),
            { text: prompt },
          ],
        },
      ],
      config: {
        responseMimeType: "application/json",
      },
    });

    // 4. Output result
    const text = result.text;
    if (!text) throw new Error("Empty response from model");

    const jsonOutput = JSON.parse(text) as unknown;
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
  "/Users/welcome/Documents/other/statements/AcctStatement_XXX7918_12042026.pdf"
);
