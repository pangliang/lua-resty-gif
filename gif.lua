-- https://wiki.whatwg.org/wiki/GIF

require 'bit'
local httpc = require("resty.http").new()

local args = ngx.req.get_uri_args()
local url = args.url
if url == nil then
    ngx.say("args url is empty")
    return
end

local delay = tonumber(args.delay) ~= nil and (tonumber(args.delay) > 255 and 255 or tonumber(args.delay)) or nil
local loop = tonumber(args.loop) ~= nil and (tonumber(args.loop) > 255 and 0 or tonumber(args.loop)) or nil

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

-- for k, v in pairs(res.headers) do  
--     ngx.header[k] = v  
-- end
ngx.header["Content-Length"] = length
ngx.header["Content-Type"] = res.headers["Content-Type"]
ngx.status=res.status

if string.sub(body, 1, 3) ~= "GIF" then
    ngx.say(body)
    return
end

local p = num(0)
if  body:byte(p()) ~= 0x47 or      
    body:byte(p()) ~= 0x49 or
    body:byte(p()) ~= 0x46 or
    body:byte(p()) ~= 0x38 or
    body:byte(p()) ~= 0x39 or
    body:byte(p()) ~= 0x61
then
    ngx.log(ngx.ERR, "Invalid GIF 89a header:", string.sub(body, 1, 6))
    -- ngx.say(body)
    return
end

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

if global_colors_table_flag then
    p(num_global_colors * 3)
end

while p(0) < body:len() do
    local block_flag = body:byte(p())
    ngx.log(ngx.STDERR, string.format("block_flag:%x, p:%x",block_flag, p(0)-1))
    if block_flag == 0x21 then
        -- 图形控制扩展(Graphic Control Extension)
        local ext_block_flag = body:byte(p())
        ngx.log(ngx.STDERR, string.format("ext_block_flag:%x",ext_block_flag))
        if ext_block_flag == 0xff then
            local bflag = {body:byte(p(), p(0)+15)}
            if bflag[1] == 0x0b and string.sub(body, p(0)+1, p(0)+11) == "NETSCAPE2.0" then
                -- application block
                ngx.log(ngx.STDERR, "NETSCAPE2.0")
                p(11) --NETSCAPE2.0
                ngx.log(ngx.STDERR, string.format("p:%x", p(0)))
                local sub_block_data_size = body:byte(p())
                local sub_block_id = body:byte(p())
                if sub_block_id == 0x01 then
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
            elseif bflag[1] == 0x0b and string.sub(body, p(0)+1, p(0)+11) == "XMP DataXMP" then
                -- XMP data
                p(11)
                skip(body, p)
            end
        elseif ext_block_flag == 0xf9 then
            -- 图形控制扩展标签(Graphic Control Label)
            local block_size = body:byte(p())
            ngx.log(ngx.STDERR, "block_size:", block_size)
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
            -- Comment Extension
            skip(body, p)
        else
            ngx.log(ngx.STDERR, string.format("unknow ext_block_flag:%x,p:%x",ext_block_flag, p(0)))
            break
        end
    elseif block_flag == 0x2c then
        -- 图像标识符(Image Descriptor)
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
    elseif block_flag == 0x3b then
        -- Trailer
        break
    else
        ngx.log(ngx.STDERR, string.format("unknow block_flag:%x,p:%x",block_flag, p(0)))
        break
    end 
end

ngx.say(body)