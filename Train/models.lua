-------------------------------------------------------------------------------
-- Define neuralnet models
-- Artem Kuharenko
-------------------------------------------------------------------------------
function get_model1()

   --options for (conv+pool+threshold) layers
   local nConvLayers = 1 --number of (conv+pool+threshold) layers
   local nFeatureMaps= {[0]=3, 32, 32} --number of feature maps in conv layers
   local filterSize = {9, 5} --filter sizes in conv layers
   local convPadding = {0, 0}
   local convStride = {1, 1}
   local poolSize = {2, 2}
   local poolStride = {2, 2}

   --options for linear layers
   local neuronsPerLinearLayer = {32} --number of neurons in linear layer

   --neuralnet model consists of submodel1 and submodel2
   local model = nn.Sequential()
   local submodel1 = nn.Sequential() --conv+pool+threshold layers
   local submodel2 = nn.Sequential() --linear layers

   --transpose batch if cuda
   if opt.cuda then
      submodel1:add(nn.Transpose({1,4},{1,3},{1,2}))
   end

   local mapsizes = {[0]=opt.width} --sizes of output of layers
   local nconnections = {[0]=0} --number of connections between i-th and (i-1) layer
   local nhiddens = {[0] = 0} --number of hidden units in layer i
   local nouts = {[0] = opt.width^2 * opt.ncolors} --number of output units in layer i

   --add first 1..nConvLayers layers (conv+pool+threshold)
   for i = 1, nConvLayers do

      local convLayer = {}
      local poolLayer = {}
      local test_batch = torch.Tensor(64, nFeatureMaps[i - 1], mapsizes[i - 1], mapsizes[i - 1])

      if opt.cuda then

         convLayer = nn.SpatialConvolutionCUDA(nFeatureMaps[i - 1], nFeatureMaps[i], filterSize[i], filterSize[i], convStride[i], convStride[i], convPadding[i])
         poolLayer = nn.SpatialMaxPoolingCUDA(poolSize[i], poolSize[i], poolStride[i], poolStride[i])
         convLayer:cuda()
         poolLayer:cuda()
         test_batch = nn.Transpose({1,4},{1,3},{1,2}):forward(test_batch):cuda()

      else

         convLayer = nn.SpatialConvolution(nFeatureMaps[i - 1], nFeatureMaps[i], filterSize[i], filterSize[i], convStride[i], convStride[i])
         poolLayer = nn.SpatialMaxPooling(poolSize[i], poolSize[i], poolStride[i], poolStride[i])

      end

      convLayer.printable = true
      convLayer.text = 'Conv layer ' .. i
      submodel1:add(convLayer)
      submodel1:add(poolLayer)
      submodel1:add(nn.Threshold(0,0))

      --get layer sizes
      local r1 = convLayer:forward(test_batch)
      local r2 = poolLayer:forward(r1)
--      print(#convLayer.output)
--      print(#poolLayer.output)
      mapsizes[i] = poolLayer.output:size(2)
      nhiddens[i] = convLayer.weight:size(2) * convLayer.weight:size(3) * convLayer.weight:size(4)
      nconnections[i] = convLayer.weight:size(1) * nhiddens[i] * (mapsizes[i - 1] - filterSize[i] + 1) ^ 2

      if opt.cuda then
         nouts[i] = poolLayer.output:size(2) * poolLayer.output:size(3) * nFeatureMaps[i]
      else
         nouts[i] = poolLayer.output:size(3) * poolLayer.output:size(4) * nFeatureMaps[i]
      end

   end

   --transpose batch if cuda
   if opt.cuda then
      submodel1:add(nn.Transpose({4,1},{4,2},{4,3}))
   end

   --reshape
   submodel2:add(nn.Reshape(nouts[nConvLayers]))

   --add linear layers
   for i = 1, #neuronsPerLinearLayer do

      nouts[nConvLayers + i] = neuronsPerLinearLayer[i]
      local linear_layer = nn.Linear(nouts[nConvLayers + i - 1], nouts[nConvLayers + i])
      linear_layer.printable = true
      linear_layer.text = 'Linear layer ' .. i
      submodel2:add(linear_layer)
      submodel2:add(nn.Threshold(0, 0))

      --get layer sizes
      mapsizes[nConvLayers + i] = 1
      nhiddens[nConvLayers + i] = neuronsPerLinearLayer[i]
      nconnections[nConvLayers + i] = nouts[nConvLayers + i - 1] * nouts[nConvLayers + i]
      nFeatureMaps[nConvLayers + i] = 1

   end

   --add classifier
   submodel2:add(nn.Linear(nouts[nConvLayers + #neuronsPerLinearLayer], #classes))
   --log probabilities
   submodel2:add(nn.LogSoftMax())

   --add submodels to model
   model:add(submodel1)
   model:add(submodel2)

   -- Loss: NLL
   local loss = nn.ClassNLLCriterion()

   if opt.cuda then
      model:cuda()
      loss:cuda()
   end

   --print sizes of nConvLayers
   for i = 0, nConvLayers + #neuronsPerLinearLayer do

      print(string.format(
      '==> model layer %2d  -  spatial extent: %3dx%3d  |  feature maps: %3d  |  hidden units: %4d  |  output size: %6d  |  connections: %9d',
      i, mapsizes[i], mapsizes[i], nFeatureMaps[i], nhiddens[i], nouts[i], nconnections[i]
      ))

   end

   --print(model.modules)
   return model, loss

end
