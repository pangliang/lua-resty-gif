-- https://wiki.whatwg.org/wiki/GIF
-- https://web.archive.org/web/20070715193723/http://odur.let.rug.nl/~kleiweg/gif/GIF89a.html#blocks

require 'bit'
local httpc = require("resty.http").new()

local args = ngx.req.get_uri_args()
local url = args.url
if url == nil then
    ngx.say("args url is empty")
    return
end

local delay = tonumber(args.delay) ~= nil and (tonumber(args.delay) > 255 and 255 or tonumber(args.delay)) or nil
local loop = tonumber(args.loop) ~= nil and (tonumber(args.loop) > 255 and 0 or tonumber(args.loop)) or 0

local res, err = httpc:request_uri(args.url, {
    method = "GET",
})
if not res then
    ngx.log(ngx.ERR, "request failed: ", err)
    return
end

function num(v)
    local t = {v or 0}
    function postinc(t, i)
      t[1] = t[1] + (i or 1)
      return t[1]
    end
    setmetatable(t, {__call=postinc})
    return t
end

function skip(body, p)
    local size = body:byte(p())
    while size ~= 0 do
        -- ngx.log(ngx.STDERR, string.format("skip size: %d/%x, p:%x", size, size, (p(0)-1)))
        p(size)
        size = body:byte(p())
    end
end

local status = res.status
local length = res.headers["Content-Length"]
local body   = res.body


ngx.header["Content-Type"] = res.headers["Content-Type"]
ngx.status=res.status

--[[
      7 6 5 4 3 2 1 0        Field Name                    Type
     +---------------+
   0 |      'G'      |       Signature                     3 Bytes
     +-             -+
   1 |      'I'      |
     +-             -+
   2 |      'F'      |
     +---------------+
   3 |               |       Version                       3 Bytes
     +-             -+
   4 |               |
     +-             -+
   5 |               |
     +---------------+
]]
if string.sub(body, 1, 6) ~= "GIF89a" then
    ngx.log(ngx.ERR, "Invalid header:", string.sub(body, 1, 6), ", url:", url)
    ngx.header["Content-Length"] = length
    ngx.say(body)
    return
end

local p = num(6)

-- Logical Screen Descriptor
--[[
      7 6 5 4 3 2 1 0        Field Name                    Type
     +---------------+
  0  |               |       Logical Screen Width          Unsigned
     +-             -+
  1  |               |
     +---------------+
  2  |               |       Logical Screen Height         Unsigned
     +-             -+
  3  |               |
     +---------------+
  4  | |     | |     |       <Packed Fields>               See below
     +---------------+
  5  |               |       Background Color Index        Byte
     +---------------+
  6  |               |       Pixel Aspect Ratio            Byte
     +---------------+
     <Packed Fields>  =      Global Color Table Flag       1 Bit
                             Color Resolution              3 Bits
                             Sort Flag                     1 Bit
                             Size of Global Color Table    3 Bits
]]
local width = body:byte(p())+(body:byte(p())*2^8)
local height = body:byte(p())+(body:byte(p())*2^8)
local pf0 = body:byte(p())
local global_colors_table_flag = bit.rshift(pf0,7)
local num_global_colors_pow2 = bit.band(pf0, 0x7)
local num_global_colors = bit.lshift(1, (num_global_colors_pow2 + 1))
local background = body:byte(p())
local pixel_aspect_radio = body:byte(p())

ngx.log(ngx.STDERR
    , string.format("w:%d,h:%d, global_colors_table_flag:%d,num_global_colors_pow2:%d,num_global_colors:%d, background:%d"
    , width, height, global_colors_table_flag, num_global_colors_pow2, num_global_colors, background)
)

-- Global Color Table
-- 3 x 2^(Size of Global Color Table+1)
--[[
      7 6 5 4 3 2 1 0        Field Name                    Type
     +===============+
  0  |               |       Red 0                         Byte
     +-             -+
  1  |               |       Green 0                       Byte
     +-             -+
  2  |               |       Blue 0                        Byte
     +-             -+
  3  |               |       Red 1                         Byte
     +-             -+
     |               |       Green 1                       Byte
     +-             -+
 up  |               |
     +-   . . . .   -+       ...
 to  |               |
     +-             -+
     |               |       Green 255                     Byte
     +-             -+
767  |               |       Blue 255                      Byte
     +===============+    
]]
if global_colors_table_flag then
    p(num_global_colors * 3)
end

local ff_ext_block_ops = 0
local loop_ext_block = false

while p(0) < body:len() do
    local block_flag = body:byte(p())
    ngx.log(ngx.STDERR, string.format("block_flag:%x, p:%x",block_flag, p(0)-1))
    if block_flag == 0x21 then
        -- Graphic Control Extension

        local ext_block_flag = body:byte(p())
        ngx.log(ngx.STDERR, string.format("ext_block_flag:%x",ext_block_flag))
        if ext_block_flag == 0xff then
            -- Application Extension Label
            --[[
                 7 6 5 4 3 2 1 0        Field Name                    Type
                +---------------+
             0  |     0x21      |       Extension Introducer          Byte
                +---------------+
             1  |     0xFF      |       Extension Label               Byte
                +---------------+
           
                +---------------+
             0  |     0x0B      |       Block Size                    Byte
                +---------------+
             1  |               |
                +-             -+
             2  |               |
                +-             -+
             3  |               |       Application Identifier        8 Bytes
                +-             -+
             4  |               |
                +-             -+
             5  |               |
                +-             -+
             6  |               |
                +-             -+
             7  |               |
                +-             -+
             8  |               |
                +---------------+
             9  |               |
                +-             -+
            10  |               |       Appl. Authentication Code     3 Bytes
                +-             -+
            11  |               |
                +---------------+
           
                +===============+
                |               |
                |               |       Application Data              Data Sub-blocks
                |               |
                |               |
                +===============+
           
                +---------------+
             0  |     0x00      |       Block Terminator              Byte
                +---------------+
            ]]

            ff_ext_block_ops = p(0)

            local application_ext_label_size = body:byte(p())

            -- Application Identifier (8 bytes) + Application Authentication Code (3 bytes)
            local application_identifier = string.sub(body, p(), p(0)+10)
            ngx.log(ngx.STDERR, string.format("Application Identifier:%s",application_identifier))
            
            p(10)
            
            if application_identifier == "NETSCAPE2.0" then
                -- NETSCAPE2.0

                -- Application Data Sub-block
                local sub_block_data_size = body:byte(p())
                local sub_block_id = body:byte(p())
                if sub_block_id == 0x01 then
                    -- Netscape Looping Application Extension (GIF Unofficial Specification)
                    -- http://www.vurdalakov.net/misc/gif/netscape-looping-application-extension
                    --[[
                            +---------------+
                         0  |     0x21      |  Extension Label
                            +---------------+
                         1  |     0xFF      |  Application Extension Label
                            +---------------+
                         2  |     0x0B      |  Block Size
                            +---------------+
                         3  |               | 
                            +-             -+
                         4  |               | 
                            +-             -+
                         5  |               | 
                            +-             -+
                         6  |               | 
                            +-  NETSCAPE   -+  Application Identifier (8 bytes)
                         7  |               | 
                            +-             -+
                         8  |               | 
                            +-             -+
                         9  |               | 
                            +-             -+
                        10  |               | 
                            +---------------+
                        11  |               | 
                            +-             -+
                        12  |      2.0      |  Application Authentication Code (3 bytes)
                            +-             -+
                        13  |               | 
                            +===============+                      --+
                        14  |     0x03      |  Sub-block Data Size   |
                            +---------------+                        |
                        15  |     0x01      |  Sub-block ID          |
                            +---------------+                        | Application Data Sub-block
                        16  |               |                        |
                            +-             -+  Loop Count (2 bytes)  |
                        17  |               |                        |
                            +===============+                      --+
                        18  |     0x00      |  Block Terminator
                            +---------------+
                    ]]

                    -- 已有 loop块
                    loop_ext_block = true

                    -- loop count
                    if loop ~= nil then
                        -- 设置loop
                        body = body:sub(1, p(0)) .. string.char(loop, 0) .. body:sub(p(0)+3)
                    end
                    local loop_count = body:byte(p())+(body:byte(p())*2^8)
                    ngx.log(ngx.STDERR, "loop_count:", loop_count)
                else
                    p(sub_block_data_size - 1)
                end
                local block_terminator = body:byte(p())
            elseif application_identifier == "XMP DataXMP" then
                -- XMP data
                skip(body, p)
            end
        elseif ext_block_flag == 0xf9 then
            -- 图形控制扩展标签(Graphic Control Label)
            --[[
                7 6 5 4 3 2 1 0        Field Name                    Type
                +---------------+
             0  |     0x21      |       Extension Introducer          Byte
                +---------------+
             1  |     0xF9      |       Graphic Control Label         Byte
                +---------------+
           
                +---------------+
             0  |     0x04      |       Block Size                    Byte
                +---------------+
             1  |0 0 0|     | | |       <Packed Fields>               See below
                +---------------+
             2  |               |       Delay Time                    Unsigned
                +-             -+
             3  |               |
                +---------------+
             4  |               |       Transparent Color Index       Byte
                +---------------+
           
                +---------------+
             0  |     0x00      |       Block Terminator              Byte
                +---------------+
                 <Packed Fields>  =     Reserved                      3 Bits
                                        Disposal Method               3 Bits
                                        User Input Flag               1 Bit
                                        Transparent Color Flag        1 Bit
            ]]


            local block_size = body:byte(p())
            local pf1 = body:byte(p())
            if delay ~= nil then
                -- 设置delay
                body = body:sub(1, p(0)) .. string.char(delay, 0) .. body:sub(p(0)+3)
            end
            local delay = body:byte(p())+(body:byte(p())*2^8)
            ngx.log(ngx.STDERR, "delay:", delay)
            local tra_color_index = body:byte(p())
            local block_terminator = body:byte(p())
        elseif ext_block_flag == 0xfe then
            -- Comment Extensio
            --[[
                7 6 5 4 3 2 1 0        Field Name                    Type
                +---------------+
             0  |     0x21      |       Extension Introducer          Byte
                +---------------+
             1  |     0xFE      |       Comment Label                 Byte
                +---------------+
           
                +===============+
                |               |
             N  |               |       Comment Data                  Data Sub-blocks
                |               |
                +===============+
           
                +---------------+
             0  |     0x00      |       Block Terminator              Byte
                +---------------+
            ]]

            skip(body, p)
        else
            ngx.log(ngx.STDERR, string.format("unknow ext_block_flag:%x,p:%x",ext_block_flag, p(0)))
            break
        end
    elseif block_flag == 0x2c then
        -- 图像标识符(Image Descriptor)
        --[[
                7 6 5 4 3 2 1 0        Field Name                    Type
               +---------------+
            0  |     0x2C      |       Image Separator               Byte
               +---------------+
            1  |               |       Image Left Position           Unsigned
               +-             -+
            2  |               |
               +---------------+
            3  |               |       Image Top Position            Unsigned
               +-             -+
            4  |               |
               +---------------+
            5  |               |       Image Width                   Unsigned
               +-             -+
            6  |               |
               +---------------+
            7  |               |       Image Height                  Unsigned
               +-             -+
            8  |               |
               +---------------+
            9  | | | |0 0|     |       <Packed Fields>               See below
               +---------------+
                <Packed Fields>  =      Local Color Table Flag        1 Bit
                                        Interlace Flag                1 Bit
                                        Sort Flag                     1 Bit
                                        Reserved                      2 Bits
                                        Size of Local Color Table     3 Bits
        ]]

        local currentFrame = {}
        currentFrame.x = body:byte(p())+(body:byte(p())*2^8)
        currentFrame.y = body:byte(p())+(body:byte(p())*2^8)
        currentFrame.w = body:byte(p())+(body:byte(p())*2^8)
        currentFrame.h = body:byte(p())+(body:byte(p())*2^8)
        currentFrame.pf0 = body:byte(p())
        ngx.log(ngx.STDERR, string.format("x:%d,y:%d,w:%d,h:%d,pf0:%x", currentFrame.x,currentFrame.y,currentFrame.w,currentFrame.h,currentFrame.pf0))

        -- 图像数据
        local lzwSize = body:byte(p())
        skip(body, p)
    elseif block_flag == 0x01 then
        -- Plain Text Extension
        --[[
            7 6 5 4 3 2 1 0        Field Name                    Type
            +---------------+
         0  |     0x21      |       Extension Introducer          Byte
            +---------------+
         1  |     0x01      |       Plain Text Label              Byte
            +---------------+
       
            +---------------+
         0  |     0x0C      |       Block Size                    Byte
            +---------------+
         1  |               |       Text Grid Left Position       Unsigned
            +-             -+
         2  |               |
            +---------------+
         3  |               |       Text Grid Top Position        Unsigned
            +-             -+
         4  |               |
            +---------------+
         5  |               |       Text Grid Width               Unsigned
            +-             -+
         6  |               |
            +---------------+
         7  |               |       Text Grid Height              Unsigned
            +-             -+
         8  |               |
            +---------------+
         9  |               |       Character Cell Width          Byte
            +---------------+
        10  |               |       Character Cell Height         Byte
            +---------------+
        11  |               |       Text Foreground Color Index   Byte
            +---------------+
        12  |               |       Text Background Color Index   Byte
            +---------------+
       
            +===============+
            |               |
         N  |               |       Plain Text Data               Data Sub-blocks
            |               |
            +===============+
       
            +---------------+
         0  |     0x00      |       Block Terminator              Byte
            +---------------+
        ]]

        p(13)
        skip(body,p)
    elseif block_flag == 0x3b then
        -- Trailer
        break
    else
        ngx.log(ngx.STDERR, string.format("unknow block_flag:%x,p:%x",block_flag, p(0)))
        break
    end 
end

if loop_ext_block == false then
    -- 没有loop 控制块, 强制加上
    body = body:sub(1, ff_ext_block_ops)
        .. string.char(0x0b)
        .. "NETSCAPE2.0"
        .. string.char(0x03, 0x01)
        .. string.char(loop, 0)
        .. string.char(0x00)
        -- 从0xff插入的, 下一个block补上0x21 0xff
        .. string.char(0x21, 0xff)
        .. body:sub(ff_ext_block_ops)
end

ngx.header["Content-Length"] = body:len()
ngx.say(body)