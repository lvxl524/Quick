#import "QCGitHubHelper.h"

static NSString * const kGitHubTokenKey = @"githubAccessToken";
static NSString * const kGitHubAPI = @"https://api.github.com";

@interface QCGitHubHelper ()
@property (nonatomic, copy, readwrite, nullable) NSString *accessToken;
@end

@implementation QCGitHubHelper

+ (instancetype)sharedHelper {
    static QCGitHubHelper *helper = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        helper = [[QCGitHubHelper alloc] init];
    });
    return helper;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        [self loadToken];
    }
    return self;
}

- (void)loadToken {
    NSDictionary *prefs = [NSDictionary dictionaryWithContentsOfFile:@"/var/mobile/Library/Preferences/com.mosheng.quickclipboard.plist"];
    self.accessToken = prefs[kGitHubTokenKey];
}

- (void)saveToken:(NSString *)token {
    self.accessToken = token;
    NSString *path = @"/var/mobile/Library/Preferences/com.mosheng.quickclipboard.plist";
    NSMutableDictionary *prefs = [NSMutableDictionary dictionaryWithContentsOfFile:path] ?: [NSMutableDictionary dictionary];
    prefs[kGitHubTokenKey] = token;
    [prefs writeToFile:path atomically:YES];
}

- (NSMutableURLRequest *)requestWithPath:(NSString *)path method:(NSString *)method {
    NSURL *url = [NSURL URLWithString:[kGitHubAPI stringByAppendingString:path]];
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url];
    req.HTTPMethod = method;
    [req setValue:@"application/vnd.github+json" forHTTPHeaderField:@"Accept"];
    [req setValue:@"2022-11-28" forHTTPHeaderField:@"X-GitHub-Api-Version"];
    if (self.accessToken) {
        [req setValue:[NSString stringWithFormat:@"Bearer %@", self.accessToken] forHTTPHeaderField:@"Authorization"];
    }
    return req;
}

- (void)loginWithPersonalAccessToken:(NSString *)token completion:(void (^)(BOOL success, NSString *message))completion {
    [self saveToken:token];
    NSMutableURLRequest *req = [self requestWithPath:@"/user" method:@"GET"];
    [[[NSURLSession sharedSession] dataTaskWithRequest:req completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        NSInteger code = [(NSHTTPURLResponse *)response statusCode];
        if (code == 200) {
            completion(YES, @"GitHub 登录成功");
        } else {
            self.accessToken = nil;
            completion(NO, [NSString stringWithFormat:@"验证失败: %@", error.localizedDescription ?: @"token 无效"]);
        }
    }] resume];
}

- (void)createRepositoryNamed:(NSString *)name completion:(void (^)(BOOL success, NSString *message))completion {
    if (!self.accessToken) { completion(NO, @"未登录"); return; }
    NSMutableURLRequest *req = [self requestWithPath:@"/user/repos" method:@"POST"];
    NSDictionary *body = @{
        @"name": name,
        @"description": @"QuickClipboard jailbreak tweak build artifacts",
        @"private": @NO,
        @"auto_init": @YES
    };
    req.HTTPBody = [NSJSONSerialization dataWithJSONObject:body options:0 error:nil];
    [req setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    [[[NSURLSession sharedSession] dataTaskWithRequest:req completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        NSInteger code = [(NSHTTPURLResponse *)response statusCode];
        if (code == 201) {
            completion(YES, [NSString stringWithFormat:@"仓库 %@ 创建成功", name]);
        } else if (code == 422) {
            completion(YES, @"仓库已存在，继续上传");
        } else {
            completion(NO, error.localizedDescription ?: [NSString stringWithFormat:@"HTTP %ld", (long)code]);
        }
    }] resume];
}

- (void)uploadDebAtPath:(NSString *)path toRepo:(NSString *)repoName completion:(void (^)(BOOL success, NSString *message))completion {
    if (!self.accessToken) { completion(NO, @"未登录"); return; }
    NSData *data = [NSData dataWithContentsOfFile:path];
    if (!data) { completion(NO, @"deb 文件不存在"); return; }
    
    NSString *filename = [path lastPathComponent];
    NSString *base64Content = [data base64EncodedStringWithOptions:0];
    NSString *apiPath = [NSString stringWithFormat:@"/repos/%@/%@/contents/Packages/%@", [self currentUsername], repoName, filename];
    
    // Check existing
    NSMutableURLRequest *getReq = [self requestWithPath:apiPath method:@"GET"];
    [[[NSURLSession sharedSession] dataTaskWithRequest:getReq completionHandler:^(NSData *getData, NSURLResponse *getResponse, NSError *getError) {
        NSString *sha = nil;
        if ([(NSHTTPURLResponse *)getResponse statusCode] == 200) {
            NSDictionary *existing = [NSJSONSerialization JSONObjectWithData:getData options:0 error:nil];
            sha = existing[@"sha"];
        }
        NSMutableURLRequest *req = [self requestWithPath:apiPath method:@"PUT"];
        NSDictionary *body = @{
            @"message": [NSString stringWithFormat:@"Add %@ via QuickClipboard", filename],
            @"content": base64Content,
            @"sha": sha ?: @""
        };
        req.HTTPBody = [NSJSONSerialization dataWithJSONObject:body options:0 error:nil];
        [req setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
        [[[NSURLSession sharedSession] dataTaskWithRequest:req completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
            NSInteger code = [(NSHTTPURLResponse *)response statusCode];
            completion(code == 200 || code == 201, code == 200 || code == 201 ? @"上传成功" : error.localizedDescription);
        }] resume];
    }] resume];
}

- (NSString *)currentUsername {
    // Simplified: extract from token scope not available; prefs stores it after login
    NSDictionary *prefs = [NSDictionary dictionaryWithContentsOfFile:@"/var/mobile/Library/Preferences/com.mosheng.quickclipboard.plist"];
    return prefs[@"githubUsername"] ?: @"";
}

@end
