local Pooling, parent = torch.class('laia.cudnn._PoolingHWNC', 'nn.Module')
local ffi = require 'ffi'
local errcheck = cudnn.errcheck

function Pooling:__init(kW, kH, dW, dH, padW, padH)
   parent.__init(self)
   self.kW = kW
   self.kH = kH
   self.dW = dW or kW
   self.dH = dH or kH
   self.padW = padW or 0
   self.padH = padH or 0
   self.iSize = torch.LongStorage(4):fill(0)
   self.ceil_mode = false
end

function Pooling:ceil()
   self.ceil_mode = true
   return self
end

function Pooling:floor()
   self.ceil_mode = false
   return self
end

function Pooling:resetPoolDescriptors()
   -- create pooling descriptor
   self.padW = self.padW or 0
   self.padH = self.padH or 0
   self.poolDesc = ffi.new('struct cudnnPoolingStruct*[1]')
   errcheck('cudnnCreatePoolingDescriptor', self.poolDesc)
   errcheck('cudnnSetPooling2dDescriptor', self.poolDesc[0], self.mode, 'CUDNN_PROPAGATE_NAN',
	    self.kH, self.kW, self.padH, self.padW, self.dH, self.dW)
   local function destroyPoolDesc(d)
      errcheck('cudnnDestroyPoolingDescriptor', d[0]);
   end
   ffi.gc(self.poolDesc, destroyPoolDesc)
end

function Pooling:createIODescriptors(input)
   assert(self.mode, 'mode is not set. (trying to use base class?)');
   local batch = true
   if input:dim() == 3 then
      input = input:view(input:size(1), input:size(2), 1, input:size(3))
      batch = false
   end
   assert(input:dim() == 4 and input:isContiguous());
   if not self.iDesc or not self.oDesc or
      input:size(1) ~= self.iSize[1] or input:size(2) ~= self.iSize[2]
   or input:size(3) ~= self.iSize[3] or input:size(4) ~= self.iSize[4] then
      self.iSize = input:size()
      local oW, oH
      if self.ceil_mode then
         oW = math.ceil((input:size(2)+self.padW*2 - self.kW)/self.dW + 1)
         oH = math.ceil((input:size(1)+self.padH*2 - self.kH)/self.dH + 1)
      else
         oW = math.floor((input:size(2)+self.padW*2 - self.kW)/self.dW + 1)
         oH = math.floor((input:size(1)+self.padH*2 - self.kH)/self.dH + 1)
      end
      assert(oW > 0 and oH > 0, 'input image smaller than kernel')
      self.output:resize(oH, oW, input:size(3), input:size(4))

      -- create input/output descriptor
      self.iDesc = laia.cudnn.createDescriptor(
	input:type(),
	{ input:size(3),      -- size N
	  input:size(4),      -- size C
	  input:size(1),      -- size H
	  input:size(2) },    -- size W
	{ input:stride(3),    -- stride N
	  input:stride(4),    -- stride C
	  input:stride(1),    -- stride H
	  input:stride(2) })  -- stride W
      self.oDesc = laia.cudnn.createDescriptor(
	self.output:type(),
	{ self.output:size(3),      -- size N
	  self.output:size(4),      -- size C
	  self.output:size(1),      -- size H
	  self.output:size(2) },    -- size W
	{ self.output:stride(3),    -- stride N
	  self.output:stride(4),    -- stride C
	  self.output:stride(1),    -- stride H
	  self.output:stride(2) })  -- stride W
      if not batch then
	self.output = self.output:view(self.output:size(1),
				       self.output:size(2),
				       self.output:size(4))
      end
   end
end

function Pooling:updateOutput(input)
   if not self.poolDesc then self:resetPoolDescriptors() end
   self:createIODescriptors(input)
   errcheck('cudnnPoolingForward', cudnn.getHandle(),
            self.poolDesc[0],
            cudnn.scalar(input, 1),
            self.iDesc[0], input:data(),
            cudnn.scalar(input, 0),
            self.oDesc[0], self.output:data());
   return self.output
end

function Pooling:updateGradInput(input, gradOutput)
   assert(gradOutput:dim() == 3 or gradOutput:dim() == 4);
   if not gradOutput:isContiguous() then
      self._gradOutput = self._gradOutput or gradOutput.new()
      self._gradOutput:resizeAs(gradOutput):copy(gradOutput)
      gradOutput = self._gradOutput
   end
   self.gradInput:resizeAs(input)
   if not self.poolDesc then self:resetPoolDescriptors() end
   self:createIODescriptors(input)
   errcheck('cudnnPoolingBackward',
            cudnn.getHandle(), self.poolDesc[0],
            cudnn.scalar(input, 1),
            self.oDesc[0], self.output:data(),
            self.oDesc[0], gradOutput:data(),
            self.iDesc[0], input:data(),
            cudnn.scalar(input, 0),
            self.iDesc[0], self.gradInput:data());
   return self.gradInput
end

function Pooling:clearDesc()
   self.poolDesc = nil
   self.iDesc = nil
   self.oDesc = nil
end

function Pooling:write(f)
   self:clearDesc()
   local var = {}
   for k,v in pairs(self) do
      var[k] = v
   end
   f:writeObject(var)
end

function Pooling:clearState()
   self:clearDesc()
   nn.utils.clear(self, '_gradOutput')
   return parent.clearState(self)
end
