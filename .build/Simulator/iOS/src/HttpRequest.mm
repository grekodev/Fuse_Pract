#include <Uno/Uno.h>

#include <Uno.Byte.h>
#include <Uno.String.h>
#include <Uno.Net.Http.HttpMessageHandlerRequest.h>

#include <Foundation/Foundation.h>

#include "HttpRequest.h"

namespace Uno {
    namespace Net {
    namespace Http {
    namespace iOS {

namespace {

    NSString *uString2NSString(uString *str)
    {
        if (str == NULL)
            return nil;

        return [NSString stringWithCharacters:str->_ptr length:str->_len];
    }

    uString *NSString2uString(NSString *str)
    {
        if (str == nil)
            return NULL;

        NSUInteger length = str.length;

        uString *result = uString::New((int) length);
        [str getCharacters:result->_ptr range:(NSRange){ 0, length }];

        return result;
    }

} // <anonymous> namespace


static NSURLCache *sharedCache = nil;
static NSURLSession *sharedSession = nil;

void SetupSharedCache(bool isCacheEnabled, size_t sizeInBytes)
{
    [sharedCache autorelease];
    [sharedSession autorelease];

    sharedCache = nil;
    sharedSession = nil;

    if (isCacheEnabled && sizeInBytes == 0)
        return;

    if (isCacheEnabled)
    {
        sharedCache = [[NSURLCache alloc] initWithMemoryCapacity:4 * 1024 * 1024
            diskCapacity:sizeInBytes diskPath:@"UnoCache"];
    }

    NSURLSessionConfiguration *config
        = [NSURLSessionConfiguration defaultSessionConfiguration];
    config.URLCache = sharedCache;

    sharedSession = [NSURLSession sessionWithConfiguration:config];
    [sharedSession retain];
}

void PurgeSharedCache()
{
    NSURLCache *cache = sharedCache;
    if (!cache)
        cache = [NSURLCache sharedURLCache];

    [cache removeAllCachedResponses];
}


struct HttpRequest::Private
{
    Private(const HttpRequest *r) : this_(const_cast<HttpRequest *>(r)) {}

    NSMutableURLRequest *request() const
    {
        if (![this_->requestTaskOrResponse_
                isKindOfClass:[NSMutableURLRequest class]])
            return nil;
        return (NSMutableURLRequest *) this_->requestTaskOrResponse_;
    }

    NSURLSessionDataTask *task() const
    {
        if (![this_->requestTaskOrResponse_
                isKindOfClass:[NSURLSessionDataTask class]])
            return nil;
        return (NSURLSessionDataTask *) this_->requestTaskOrResponse_;
    }

    NSHTTPURLResponse *response() const
    {
        if (![this_->requestTaskOrResponse_
                isKindOfClass:[NSHTTPURLResponse class]])
            return nil;
        return (NSHTTPURLResponse *) this_->requestTaskOrResponse_;
    }

    void Abort()
    {
        [task() cancel];

        uAutoReleasePool pool;
        this_->unoRequest_->OnAborted();
    }

    void Completed(NSData *data, NSHTTPURLResponse *response, NSError *error)
    {
        [response retain];
        [this_->requestTaskOrResponse_ release];

        this_->requestTaskOrResponse_ = response;

        uAutoReleasePool pool;

        if (data && data.length)
        {
            switch (this_->unoRequest_->HttpResponseType())
            {
                case 0:       // String
                    this_->responseContent_ = uString::Utf8(
                        (const char *) data.bytes, (int) data.length);
                    break;

                case 1:    // ByteArray
                    this_->responseContent_ = uArray::New(
                        ::g::Uno::Byte_typeof()->Array(), (int) data.length, data.bytes);
                    break;

                default:
                    break;
            }
        }

        if (error)
        {
            if (error.code == NSURLErrorTimedOut
                    && [error.domain isEqualToString:NSURLErrorDomain])
            {
                this_->unoRequest_->OnTimeout();
            }
            else
            {
                uString *message = NSString2uString(error.localizedDescription);
                this_->unoRequest_->OnError(message);
            }
        }
        else
        {
            this_->unoRequest_->OnDone();
        }
    }

    HttpRequest *this_;
};

HttpRequest::HttpRequest(
        ::g::Uno::Net::Http::HttpMessageHandlerRequest* unoRequest,
        uString *method, uString *url)
    : unoRequest_(unoRequest)
    , requestTaskOrResponse_(nil)
{
    NSMutableURLRequest *request = [[NSMutableURLRequest alloc]
        initWithURL:[NSURL
            URLWithString:uString2NSString(url)]];
    request.HTTPMethod = uString2NSString(method);

    requestTaskOrResponse_ = request;
}

HttpRequest::~HttpRequest()
{
    [requestTaskOrResponse_ release];
}

void HttpRequest::SetTimeout(int ms)
{
    Private(this).request().timeoutInterval = ms / 1000.;
}

void HttpRequest::SetCacheEnabled(bool isCacheEnabled)
{
    Private(this).request().cachePolicy = isCacheEnabled
        ? NSURLRequestUseProtocolCachePolicy
        : NSURLRequestReloadIgnoringLocalCacheData;
}

void HttpRequest::SetHeader(uString *key, uString *value)
{
    NSString *headerField = uString2NSString(key);
    NSString *headerContent = uString2NSString(value);

    if ([@"Range" caseInsensitiveCompare:headerField])
    {
        // Caching is broken for HTTP Range requests
        SetCacheEnabled(false);
    }

    [Private(this).request() addValue:headerContent
        forHTTPHeaderField:headerField];
}

void HttpRequest::SendAsync(uString *content)
{
    struct RAII
    {
        ~RAII() { uFreeCStr(ptr); }
        RAII(uString *d)
            : ptr(uStringToCStr(d))
            , length(::strlen(ptr))
        {
        }

        const char *ptr;
        size_t length;
    };

    RAII data(content);
    SendAsync(data.ptr, data.length);
}

void HttpRequest::SendAsync(const void *data, size_t length)
{
    if (data && length)
    {
        Private(this).request().HTTPBody
            = [NSData dataWithBytes:data length:length];
    }

    NSURLSession *session = sharedSession;
    if (!session)
        session = [NSURLSession sharedSession];

    NSURLSessionDataTask *task = [session
        dataTaskWithRequest:Private(this).request()
        completionHandler:^void (NSData *d, NSURLResponse *r, NSError *e)
        {
            dispatch_async(dispatch_get_main_queue(), ^{
                Private(this).Completed(d, (NSHTTPURLResponse *) r, e);
            });
        }];

    [task retain];
    [requestTaskOrResponse_ release];

    requestTaskOrResponse_ = task;
    [task resume];
}

void HttpRequest::Abort()
{
    Private(this).Abort();
}

int HttpRequest::GetResponseStatus() const
{
    return (int) Private(this).response().statusCode;
}

uString *HttpRequest::GetResponseHeader(uString *key) const
{
    NSString *value = [Private(this).response().allHeaderFields
        objectForKey:uString2NSString(key)];
    return NSString2uString(value);
}

uString *HttpRequest::GetResponseHeaders() const
{
    NSDictionary *headers = Private(this).response().allHeaderFields;

    __block size_t resultLength = 0;
    [headers enumerateKeysAndObjectsUsingBlock:
            ^(NSString *key, NSString *obj, BOOL *stop)
    {
        resultLength = resultLength + key.length + obj.length + 2;
    }];

    if (resultLength == 0)
        return NULL;

    uString *result = uString::New((int) (resultLength - 1));
    __block uChar *ptr = result->_ptr;
    uChar *ptrEnd = result->_ptr + result->_len;

    [headers enumerateKeysAndObjectsUsingBlock:
            ^(NSString *key, NSString *obj, BOOL *stop)
    {
        assert(ptrEnd > ptr);

        NSUInteger keyLength = key.length;
        assert(ptrEnd - ptr > keyLength);

        [key getCharacters:ptr range:(NSRange){ 0, keyLength }];
        ptr += keyLength;

        *ptr++ = (uChar) ':';

        NSUInteger objLength = obj.length;
        assert(ptrEnd - ptr >= objLength);

        [obj getCharacters:ptr range:(NSRange){ 0, objLength }];
        ptr += objLength;

        // NOTE: Overwrites terminating NULL on last iteration
        *ptr++ = (uChar) '\n';
    }];

    assert(--ptr == ptrEnd);
    *ptr = '\0';

    return result;
}

uString *HttpRequest::GetResponseContentString() const
{
    return uAs< uString *>(
        (uObject *&)responseContent_, ::g::Uno::String_typeof());
}

uArray *HttpRequest::GetResponseContentByteArray() const
{
    return uAs< uArray *>(
        (uObject *&)responseContent_, ::g::Uno::Byte_typeof()->Array());
}

}}}} // namespace Uno::Net::Http::Implementation::iOS
