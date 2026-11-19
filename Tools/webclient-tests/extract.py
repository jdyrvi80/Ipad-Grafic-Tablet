import re,sys
html=open(__import__('os').path.join(__import__('os').path.dirname(__file__),'../../Mac/Resources/WebClient.html')).read()
codec=re.search(r'/\* CODEC-BEGIN.*?\*/(.*?)/\* CODEC-END \*/',html,re.S).group(1)
hm=re.search(r'/\* HMAC-BEGIN.*?\*/(.*?)/\* HMAC-END \*/',html,re.S).group(1)
open('lib.js','w').write(codec+hm+"\nmodule.exports={Codec,FrameDecoder,hmacSha256,sha256,toHex,MT,FLAG,GK,CMD,utf8Enc};\n")
