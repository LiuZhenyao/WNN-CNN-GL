require 'nn'

local function block(network, filters)
  network:add(nn.SpatialBatchNormalization(filters,1e-3))
  network:add(nn.ReLU(true))
  network:add(nn.SpatialConvolution(filters, filters, 1, 1, 1, 1, 0, 0))
  network:add(nn.SpatialBatchNormalization(filters,1e-3))
  network:add(nn.ReLU(true))
  network:add(nn.SpatialConvolution(filters, filters, 1, 1, 1, 1, 0, 0))
  network:add(nn.SpatialBatchNormalization(filters,1e-3))
  network:add(nn.ReLU(true))
end

function build_network_model(gpu)
  local base_encoder = nn.Sequential()
  base_encoder:add(nn.SpatialConvolution( 3, 96, 11, 11, 4, 4, 5, 5))
  block(base_encoder, 96)
  base_encoder:add(nn.SpatialMaxPooling(3, 3, 2, 2, 1, 1))
  base_encoder:add(nn.Dropout(0.2))

  base_encoder:add(nn.SpatialConvolution(96, 256, 5, 5, 1, 1, 2, 2))
  block(base_encoder, 256)
  base_encoder:add(nn.SpatialMaxPooling(3, 3, 2, 2, 1, 1))
  base_encoder:add(nn.Dropout(0.2))

  base_encoder:add(nn.SpatialConvolution(256, 384, 3, 3, 1, 1, 1, 1))
  block(base_encoder, 384)
  base_encoder:add(nn.SpatialMaxPooling(3, 3, 2, 2, 1, 1))
  base_encoder:add(nn.Dropout(0.2))
  
  local base_encoder_init = require('weight-init')(base_encoder, 'MSRinit')
  local base_encoder_clone = base_encoder_init:clone()
  base_encoder_clone:share(base_encoder_init, 'weight', 'bias', 'gradWeight', 'gradBias', 'running_mean', 'running_std', 'running_var')
  
  local siamese_encoder = nn.ParallelTable()
  siamese_encoder:add(base_encoder_init)
  siamese_encoder:add(base_encoder_clone) 

  local top_encoder = nn.Sequential()

  top_encoder:add(nn.SpatialConvolution(2*384, 1024, 3, 3, 1, 1, 1, 1))
  block(top_encoder, 1024)
  top_encoder:add(nn.SpatialAveragePooling(8,8,1,1))

  top_encoder:add(nn.View(-1):setNumInputDims(3))

  local top_encoder_init = require('weight-init')(top_encoder, 'MSRinit')

  local pred_layer_r = nn.Linear(3072, 1)
  local pred_layer_t = nn.Linear(3072, 2)
  pred_layer_r.weight:zero()
  pred_layer_r.bias:zero()
  pred_layer_t.weight:zero()
  pred_layer_t.bias:zero()
  local pred_layer = nn.ConcatTable()
  pred_layer:add(pred_layer_r)
  pred_layer:add(pred_layer_t)

  local model = nn.Sequential()
  model:add(siamese_encoder)
  model:add(nn.JoinTable(2))
  model:add(top_encoder_init)
  model:add(pred_layer)
  model:add(nn.JoinTable(2))
  model:add(nn.View(-1,3))

  local input = torch.Tensor(2, 3, 240, 320)

  if gpu>0 then
    model = model:cuda()
    input = input:cuda()
    cudnn.convert(model, cudnn)
    local optnet = require 'optnet'
    optnet.optimizeMemory(model, {input,input}, {inplace=true, mode='training'})
  end

  return model
end

function build_network_model_pretrain(gpu)
  local base_encoder = nn.Sequential()
  base_encoder:add(nn.SpatialConvolution( 3, 96, 11, 11, 4, 4, 5, 5))
  block(base_encoder, 96)
  base_encoder:add(nn.SpatialMaxPooling(3, 3, 2, 2, 1, 1))
  base_encoder:add(nn.Dropout(0.2))

  base_encoder:add(nn.SpatialConvolution(96, 256, 5, 5, 1, 1, 2, 2))
  block(base_encoder, 256)
  base_encoder:add(nn.SpatialMaxPooling(3, 3, 2, 2, 1, 1))
  base_encoder:add(nn.Dropout(0.2))

  base_encoder:add(nn.SpatialConvolution(256, 384, 3, 3, 1, 1, 1, 1))
  block(base_encoder, 384)
  base_encoder:add(nn.SpatialMaxPooling(3, 3, 2, 2, 1, 1))
  base_encoder:add(nn.Dropout(0.2))
  base_encoder:add(nn.View(-1):setNumInputDims(3))
  
  local base_encoder_init = require('weight-init')(base_encoder, 'MSRinit')
  local base_encoder_clone = base_encoder_init:clone()
  base_encoder_clone:share(base_encoder_init, 'weight', 'bias', 'gradWeight', 'gradBias', 'running_mean', 'running_std', 'running_var')
  
  local siamese_encoder = nn.ParallelTable()
  siamese_encoder:add(base_encoder_init)
  siamese_encoder:add(base_encoder_clone) 

  local model = nn.Sequential()
  model:add(siamese_encoder)
  model:add(nn.PairwiseDistance(2)) --L2 pariwise distance

  local input = torch.Tensor(2, 3, 240, 320)

  if gpu>0 then
    model = model:cuda()
    input = input:cuda()
    cudnn.convert(model, cudnn)
    local optnet = require 'optnet'
    optnet.optimizeMemory(model, {input,input}, {inplace=true, mode='training'})
  end

  return model
end

function load_network_model_pretrain(gpu, filename)
  local siamese_encoder = torch.load(filename)
  siamese_encoder:remove(#siamese_encoder) --nn.PairwiseDistance
  siamese_encoder.modules[1].modules[1]:remove(34) --nn.View from curr branch 
  siamese_encoder.modules[1].modules[2]:remove(34) --nn.View from base branch 
  --[[
  --freeze weights
  for i=1, #siamese_encoder.modules[1].modules[1] do
    siamese_encoder.modules[1].modules[1].modules[i].accGradParameters = function(i, o ,e) end
    siamese_encoder.modules[1].modules[1].modules[i].updateParameters = function(i, o, e) end
    siamese_encoder.modules[1].modules[2].modules[i].accGradParameters = function(i, o ,e) end
    siamese_encoder.modules[1].modules[2].modules[i].updateParameters = function(i, o, e) end
  end
  --]]
  local top_encoder = nn.Sequential()

  top_encoder:add(nn.SpatialConvolution(2*384, 1024, 3, 3, 1, 1, 1, 1))
  block(top_encoder, 1024)
  top_encoder:add(nn.SpatialAveragePooling(8,8,1,1))

  top_encoder:add(nn.View(-1):setNumInputDims(3))

  local top_encoder_init = require('weight-init')(top_encoder, 'MSRinit')

  local pred_layer_r = nn.Linear(3072, 3)
  local pred_layer_t = nn.Linear(3072, 3)
  pred_layer_r.weight:zero()
  pred_layer_r.bias:zero()
  pred_layer_t.weight:zero()
  pred_layer_t.bias:zero()
  local pred_layer = nn.ConcatTable()
  pred_layer:add(pred_layer_r)
  pred_layer:add(pred_layer_t)

  local model = nn.Sequential()
  model:add(siamese_encoder)
  model:add(nn.JoinTable(2))
  model:add(top_encoder_init)
  model:add(pred_layer)
  model:add(nn.JoinTable(2))
  model:add(nn.View(-1,6))

  local input = torch.Tensor(2, 3, 240, 320)

  if gpu>0 then
    model = model:cuda()
    input = input:cuda()
    cudnn.convert(model, cudnn)
    local optnet = require 'optnet'
    optnet.optimizeMemory(model, {input,input}, {inplace=true, mode='training'})
  end

  return model
end

--[[
require 'cudnn'
--local model = load_network_model_pretrain(1, 'pretrain_model.t7')
local model = build_network_model(1)

local input = torch.Tensor(2, 3, 240, 320)

input = input:cuda()
model = model:cuda()

local output = model:forward({input,input})

print(model)
print(output:size())

params, grad_params = model:getParameters()
print('Number of parameters ' .. params:size(1))

--]]
