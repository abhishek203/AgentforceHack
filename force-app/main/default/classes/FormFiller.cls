public with sharing class FormFiller {

    // ----------------------------------------------------------
    // 1. Inner class to wrap Flow inputs
    // ----------------------------------------------------------
    public class InputWrapper {
        @InvocableVariable
        public Id contactId;

        @InvocableVariable
        public Id benefitId;
    }

    // ----------------------------------------------------------
    // 2. Inner classes for building the OpenAI request/response
    // ----------------------------------------------------------
    
    // Represents the body for the Chat Completion request
    private class OpenAIRequest {
        public String model;
        public List<Map<String, String>> messages;
        public Integer max_tokens;

        public OpenAIRequest(String prompt) {
            // Replace 'gpt-4-turbo-preview' with the actual model if needed
            this.model = 'gpt-4-turbo-preview';
            this.max_tokens = 4096;
            this.messages = new List<Map<String, String>>{
                new Map<String, String>{ 'role' => 'user', 'content' => prompt }
            };
        }
    }

    // Represents the main OpenAI response structure
    private class OpenAIResponse {
        public List<OpenAIChoice> choices;
    }

    // Represents each choice within the OpenAI response
    private class OpenAIChoice {
        public OpenAIMessage message;
    }

    // Represents the 'message' object returned by the Chat Completion
    private class OpenAIMessage {
        public String role;
        public String content;
    }

    // ----------------------------------------------------------
    // 3. Main method called by Flow (Invocable Method)
    // ----------------------------------------------------------
    /**
     * Invocable methods can only accept a single parameter of type List.
     * That parameter can be a list of a custom Apex type, sObject, or a primitive.
     *
     * This method returns a List of Strings, where each entry in the list
     * is the publicly accessible URL of the newly generated text file for that InputWrapper.
     */
    @InvocableMethod
    public static List<String> processPdfForm(List<InputWrapper> inputList) {
        
        // The final results: one public link per input record
        List<String> publicLinks = new List<String>();

        // Loop through each Flow input
        for (InputWrapper input : inputList) {

            

            // 2) Fetch the Benefit__c record (has PDF_xml__c)
            Benefit__c benefitRecord = [
                SELECT Id, PDF_xml__c
                FROM Benefit__c
                WHERE Id = :input.benefitId
                LIMIT 1
            ];
            String pdfContent = benefitRecord.PDF_xml__c;

            // 3) Build a userDetails map from the Contact record
            Map<String, String> userDetails = new Map<String, String>{
                'ContactName'  => 'John A Smith',
                'ContactEmail' => 'john@gmail.com',
                'ContactPhone' => '1234566'
            };

            // 4) Construct the prompt
            String prompt = 
                'Here is the content of a government benefits document:\n'
                + pdfContent
                + '\nPlease fill in the following details accurately:\n'
                + JSON.serializePretty(userDetails)
                + '\nReturn the completed form content clearly structured as plain text.';

            // 5) Call OpenAI (raw text output will be used as file content)
            String response = callOpenAI(prompt);
            System.debug(LoggingLevel.INFO, 'OpenAI Response: ' + response);


            // 7) Convert the text output to a Blob
            Blob fileBlob = Blob.valueOf(response);

            // 8) Create a ContentVersion record (this auto-creates ContentDocument)
            // Note: We are now saving as a text file instead of a PDF
            ContentVersion cv = new ContentVersion(
                Title       = 'Generated Text File - ' + 'John',
                PathOnClient = 'CompletedForm.txt',
                VersionData = fileBlob
            );
            insert cv;

            // 9) Re-query to get the ContentDocumentId for the inserted ContentVersion
            cv = [
                SELECT Id, ContentDocumentId
                FROM ContentVersion
                WHERE Id = :cv.Id
                LIMIT 1
            ];
            Id docId = cv.ContentDocumentId;

            // 10) Generate a public link (ContentDistribution)
            ContentDistribution dist = new ContentDistribution(
                Name                      = 'Public Link - ' + 'John',
                ContentVersionId          = cv.Id,
                PreferencesAllowViewInBrowser = true,
                PreferencesExpires        = false, 
                PreferencesPasswordRequired = false
            );
            insert dist;

            // 11) Re-query to get the generated public URL (DistributionPublicUrl)
            dist = [
                SELECT DistributionPublicUrl, Password
                FROM ContentDistribution
                WHERE Id = :dist.Id
                LIMIT 1
            ];

            // 12) Add the public link to the results
            publicLinks.add(dist.DistributionPublicUrl);
            System.debug('LINK:' + dist.DistributionPublicUrl);
        }

        // Return public URLs (one per input record)
        return publicLinks;
    }

    // ----------------------------------------------------------
    // 4. Helper method to call OpenAI Chat Completions endpoint
    // ----------------------------------------------------------
    private static String callOpenAI(String prompt) {
        Http http = new Http();
        HttpRequest req = new HttpRequest();
        req.setEndpoint('https://api.openai.com/v1/chat/completions');
        req.setMethod('POST');
        req.setHeader('Content-Type', 'application/json');

        // IMPORTANT: For production, store your API key securely 
        // (e.g. Named Credentials, Custom Metadata, etc.)
        req.setHeader('Authorization', 'Bearer ' + '{!.OAuthToken}'); 

        // Build the request body
        OpenAIRequest body = new OpenAIRequest(prompt);
        req.setBody(JSON.serialize(body));
        System.debug('Outgoing OpenAI request: ' + req);

        // Send the request (timeout set to 120 seconds)
        req.setTimeout(120000);
        HttpResponse res = http.send(req);

        // Parse the response
        OpenAIResponse openAIResponse = (OpenAIResponse) JSON.deserialize(res.getBody(), OpenAIResponse.class);

        // Return the content from the first choice
        return (openAIResponse.choices != null && !openAIResponse.choices.isEmpty())
            ? openAIResponse.choices[0].message.content
            : '';
    }
}
