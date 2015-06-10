/**

Alamofire is a pretty great networking framework that takes advantage
of the functional programming concepts in Swift.  It enables you to
write custom methods to deserialize your network data into whatever
format you want, and does that work on a background thread.  Here's a
way you can use functional programming techniques with generics to
avoid repetition, guarantee type safety, and isolate the core logic of deserialization.

For simplicity, I'll refer to a JSON class that wraps the
primitive/dict/array types that can be created from parsing a json
string. 

Here's how you might write a Alamofire request with response callback without a custom serializer:
*/
class ListingBuilder {
  class func fromJSON(json: JSON) -> (Listing?, NSError?) {
    // Imagine that this does the work of deserializing the listing from the json, or returns an error.
    return (nil, nil)
  }
}

func fetchListing() {

  request.responseJSON { (req, res, json, err) in
    if let err = err {		
      // handle networking error
    } else if let json = JSON(json) {
      let (listing, error) = ListingBuilder.fromJSON(json)
      // actually do what we want with listings
    } else {
      // there wasn't an error or json
    }
}

/** 

This code requires you to make the model
deserialization call in every callback.  More importantly, the
deserialization happens on the main thread, instead of on the
background thread where the json parsing happens.  With a custom serializaer you can simplify
your completion block and do the deserialization in the background.

I like to keep my models as thin as possible, so I put the serializer
code as a static method in a separate class.

*/

request.responseListing { (req, res, listing, err) in 
  if let err = err {
    // regular error handling
  } else if let listing = listing {
    // do what we want with listing
  }
}

class ListingResponse {

  class func serializer(req: NSURLRequest, res: NSHTTPURLResponse?, data: NSData?) -> (Listing?, NSError?) {

    let JSONSerializer = Alamofire.Request.JSONResponseSerializer(options: .AllowFragments)
    let (json, error) = JSONSerializer(req, res, data)

    if let error = error {
      return (nil, error)
    } else if let json = JSON(json) {
      return ListingBuilder.fromJSON(json) 
    } else {
      return (nil, ErrorMake("json parsing returned nil")
    }
  }
}

extension Alamofire.Response {
  func responseListing(completion: (NSURLRequest, NSHTTPResponse, Listing?, NSError?) -> Void) -> Self {

    // We need to adapt from the regular response completion type that
    // passes AnyObject? to our completion that passes Listing?
    let completionWrap = { (req, res, object, err) in
      if let err = err {
        completion(req, res, nil, err)
      else if let listing = object as? Listing {
        completion(req, res, listing, err)
      } else {
        completion(req, res, nil, ErrorMake("wrong type returned but no error given"))
      }
    }  

    return response(serializer: ListingResponse.serializer, completion: completionWrap)
  }
}

/** 

This makes our requests simpler and separates the serializer logic,
but when we want to use this pattern with another Model object we'll
find ourselves repeating a lot of the same code.  The only first
obvious difference is the call to `ListingBuilder.fromJSON`. Using
first-class functions, we can pass that `fromJSON` function as an
argument to our serializer.  I decided to call a `ModelBuilder.fromJSON`
function type a "Modelizer," much like the Serializer type that
Alamofire defines.  So now we have a method that takes a Modelizer
function and returns a Serializer function.

*/

class ModelResponse {

  typealias Modelizer = (JSON) -> (AnyObject?, NSError?)

  // Remember, Alamofire.Response.Serializer is just an alias for `(NSURLRequest, NSHTTPURLReponse?, NSData?) -> (AnyObject? NSError?)`
  class func serializer(modelizer: Modelizer) -> Alamofire.Response.Serializer {
     return { req, res, data in 
       let JSONSerializer = Alamofire.Request.JSONResponseSerializer(options: .AllowFragments)
       let (json, error) = JSONSerializer(req, res, data)

       if let error = error {
         return (nil, error)
       } else if let json = JSON(json) {
       	 return modelizer(json)
       }
     }
  }

}

/**

Now we can have multiple response types sharing the same json parsing
and type checks, with just a small difference between them.

*/

extension Alamofire.Response {

  func responseListing(completion: (NSURLRequest, NSHTTPResponse, Listing?, NSError?) -> Void) -> Self {
    let completionWrap = { (req, res, object, err) in
      if let err = err {
        completion(req, res, nil, err)
      else if let listing = object as? Listing {
        completion(req, res, listing, err)
      } else {
        completion(req, res, nil, ErrorMake("wrong type returned but no error given"))
      }
    }  

    let serializer = ModelResponse.serializer(ListingBuilder.fromJSON)
    return response(serializer: serializer, completion: completionWrap)
  }

  func responseUnit(completion: (NSURLRequest, NSHTTPResponse, Unit?, NSError?) -> Void) -> Self {
    let completionWrap = { (req, res, object, err) in
      if let err = err {                           
        completion(req, res, nil, err)
      else if let unit = object as? Unit {
        completion(req, res, unit, nil)
      } else {
        completion(req, res, nil, ErrorMake("wrong type returned but no error given"))
      }
    }  

    let serializer = ModelResponse.serializer(UnitBuilder.fromJSON)
    return response(serializer: serializer, completion: completionWrap)
  }
}


/**

We still have some repetition in the `completionWrap` code, and the
only difference between instances is the type we are attempting to
cast. How do we determine that type? Each custom serializer always
returns the model type we want, even though the type signature on
`ModelResponse.serializer` doesn't say so.  

We can parameterize that type using Generics, which will allow us to
specify the model type in the modelizer, serializer, and completion
signatures.  Swift can infer the type from the arguments you pass, but
it can also be useful to be explicit.

One caveat: because Alamofire.Response.Serializer passes AnyObject, we
have to constrain our generic to extend from AnyObject. (You can get
around this by wrapping your struct in a simple class.) 

*/

class ModelResponse<ModelType: AnyObject> {

  typealias Modelizer = (JSON) -> (ModelType?, NSError?)
  typealias ModelSerializer = (NSURLRequest, NSHTTPURLReponse?, NSData?) -> (ModelType?, NSError?)
  typealias Completion = (NSURLRequest, NSHTTPURLResponse?, ModelType?, NSError?) -> Void

  class func serializer(modelizer: Modelizer) -> ModelSerializer {
     return { req, res, data in 
       let (json, error) = parseJSON(data)
       if let error = error {
         return (nil, error)
       } else if let json = json {
       	 return modelizer(json)
       }
     }
  }
}


extension Alamofire.Response {
    func responseModel<ModelType: AnyObject> (
        modelizer: ModelResponse<ModelType>.Modelizer,
        completion: ModelResponse<ModelType>.Completion
        ) -> Self
    {
      let completionWrap = { (req, res, object, err) in
        if let err = err {                           
          completion(req, res, nil, err)
        // We still have to do a cast here due to the original response completion type signature
        else if let unit = object as? ModelType {
          completion(req, res, unit, nil)
        } else {
          completion(req, res, nil, ErrorMake("wrong type returned but no error given"))
        }
      }  
      
      let serializer = ModelResponse.serializer(modelizer)        
      return response(serializer, completionHandler: completionWrap)
    }

  func responseListing(completion: (NSURLRequest, NSURLHTTPResponse?, Listing?, NSError?) -> Void) -> Self {
    return responseModel(modelizer: ListingBuilder.fromJSON, completion: completion)
  }

  func responseUnit(completion: (NSURLRequest, NSURLHTTPResponse?, Unit?, NSError?) -> Void) -> Self {
    return responseModel(modelizer: UnitBuilder.fromJSON, completion: completion)
  }
}

/**

So there you have it.  This should give you a good sense of how to use
first-class functions and generics to reduce code duplication while
maintaining readability.

After I did all the work here, the Alamofire documentation suggested
another approach by having your model classes implement a protocol,
(https://github.com/Alamofire/Alamofire#generic-response-object-serialization).
One difference is that my implementation allows you to completely
separate your deserialization code from the model classes.

*/
