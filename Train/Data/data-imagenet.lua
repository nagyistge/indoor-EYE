----------------------------------------------------------------------
-- Load imagenet dataset
-- Artem Kuharenko
-- Alfredo Canziani, Feb 2014
-- Use Clement Farabet scripts
----------------------------------------------------------------------

require 'torch'
require 'llthreads'
require 'sys'
require 'image'

function extract_square_patch(sample)

   -- extract square patch
   local size = math.min(sample:size(2), sample:size(3))
   local t = math.floor((sample:size(2) - size)/2 + 1)
   local l = math.floor((sample:size(3) - size)/2 + 1)
   local b = t + size - 1
   local r = l + size - 1
   sample = sample[{ {},{t,b},{l,r} }]

   return sample

end

function load_raw_imagenet(src_data_file, src_info_file, sfile, fact)
   --load whole resized imagenet images from memory-mapped file

   print('==> Loading raw imagenet')
   local dt = {}

   if fact == 'load' and paths.filep(opt.temp_dir .. sfile) then
      print('======> Loading data from file')
      dt = torch.load(opt.temp_dir .. sfile)
   else

      local opt = opt or {}
      opt.width = opt.width or 46
      opt.height = opt.height or 46

      local d = torch.load(src_info_file)
      local jpegs = torch.ByteStorage(src_data_file)

      local jpegs_p   = ffi.cast('unsigned char *', ffi.cast('intptr_t', torch.data(jpegs)))
      local offsets_p = ffi.cast('unsigned long *', ffi.cast('intptr_t', torch.data(d.offsets)))
      local sizes_p   = ffi.cast('unsigned long *', ffi.cast('intptr_t', torch.data(d.sizes)))
      local gm = require 'graphicsmagick'

      local n = d.labels:size(1)
      dt.data = torch.FloatTensor(n, 3, opt.height, opt.width)
      dt.labels = torch.Tensor(n)
      dt.imagenet_labels = torch.Tensor(n)

      for i = 1, n do

         xlua.progress(i, n)

         local offset = tonumber(offsets_p[i-1] - 1)
         local size = tonumber(sizes_p[i-1])
         local jpegblob = jpegs_p + offset

         local sample = gm.Image():fromBlob(jpegblob,size):toTensor('float','RGB','DHW',true)
         sample = extract_square_patch(sample)
         sample = image.scale(sample, opt.width, opt.height)

         for j = 1, opt.ncolors do
            sample[j]:add(-global_mean[j])
            sample[j]:div(global_std[j])
         end

         dt.data[i] = sample
         dt.labels[i] = d.labels[i]
         dt.imagenet_labels[i] = d.imagenet_labels[i]

      end

      dt.classes = d.classes

      if fact == 'save' then
         print('======> saving data')
         torch.save(opt.temp_dir .. sfile, dt)
      end

   end

   return dt

end

opt = opt or {}
opt.batchSize = opt.batchSize or 128
opt.receptive = 256
opt.distort = false
opt.jitter = 0
opt.gm = 0
opt.lm = false
opt.ls = false
----------------------------------------------------------------------
--scripts for async load with memory mapping

-- dimensions
--local c,h,w = 3, math.abs(opt.receptive), math.abs(opt.receptive)
local c,h,w=3, opt.height, opt.width
local bs = opt.batchSize

function prepare_async(data_file, info_file)

   local dataset = torch.load(info_file)
   dataset.data = torch.ByteStorage(data_file)

   local nsamples = dataset.labels:size(1)
   local samples = torch.FloatTensor(bs, c, h, w)
   local targets = torch.FloatTensor(bs)
   local jpegs = dataset.data
   local offsets = dataset.offsets
   local sizes = dataset.sizes
   local labels = dataset.labels
   local shuffle = torch.randperm(nsamples):type('torch.LongTensor')

   --shuffle = torch.range(1, nsamples):type('torch.LongTensor')

   -- com is a shared state between the main thread and
   -- the batch thread, it holds two variables:
   -- com[0]: the index of the batch to generate (if 0, then the thread is idle)
   -- com[1]: whether the batch is used for test or not (1 for test)
   local com = ffi.new('unsigned long[3]', {0,0})

   local samplesCUDA={}
   local targetsCUDA={}
   if opt.cuda then
      samplesCUDA = samples:clone():cuda()
      targetsCUDA = targets:clone():cuda()
   end

   -- size:
   local function nbatches()
      return math.floor(nsamples / bs)
   end

   -- block:
   local block = function(...)
      -- libs
      require 'sys'
      require 'torch'
      require 'torchffi'
      local gm = require 'graphicsmagick'
      require 'image'

      --local distort = require 'distort'

      -- args:
      local args = {...}
      local nsamples = args[2]
      local bs = args[3]
      local c = args[4]
      local h = args[5]
      local w = args[6]
      local distorton = args[7]
      local jitter = args[8]
      local receptive = args[9]
      --      local global_mean = args[10]
      local local_mean = args[11]
      local local_std = args[12]
      local shuffle_p = ffi.cast('unsigned long *', args[13])
      local samples_p = ffi.cast('float *', args[14])
      local targets_p = ffi.cast('float *', args[15])
      local jpegs_p   = ffi.cast('unsigned char *', args[16])
      local offsets_p = ffi.cast('unsigned long *', args[17])
      local sizes_p   = ffi.cast('unsigned long *', args[18])
      local labels_p  = ffi.cast('unsigned long *', args[19])
      local com       = ffi.cast('unsigned long *', args[20])
      local gm_p      = ffi.cast('float *', args[21])
      local std_p      = ffi.cast('float *', args[22])

      local gmStorage = torch.FloatStorage(c, tonumber(ffi.cast('intptr_t', gm_p)))
      local global_mean = torch.FloatTensor(gmStorage)
      local stdStorage = torch.FloatStorage(c, tonumber(ffi.cast('intptr_t', std_p)))
      local global_std = torch.FloatTensor(stdStorage)

      -- map samples batch to given pointer:
      local samplesStorage = torch.FloatStorage(bs*c*h*w, tonumber(ffi.cast('intptr_t',samples_p)))
      local samples = torch.FloatTensor(samplesStorage):resize(bs,c,h,w)

      -- process batches in a loop:
      while true do
         -- next batch?
         while tonumber(com[0]) == 0 do
            sys.sleep(.005)
         end
         local idx = tonumber(com[0])

         -- train or test?
         local test = (com[1] == 1)

         -- zero batch
         samples:zero()

         -- process batch:
         for i = 0,bs-1 do
            -- offsets:
            local start = ((idx-1)*bs + i) % nsamples
            local ii = shuffle_p[start] - 1

            -- decode jpeg:
            local offset = tonumber(offsets_p[ii] - 1)
            local size = tonumber(sizes_p[ii])
            local jpegblob = jpegs_p + offset
            local sample = gm.Image():fromBlob(jpegblob,size):toTensor('float','RGB','DHW',true)

            -- distort sample
            if distorton and not test then
               -- rot + flip + scale:
               sample = distort(sample, 0.25,.33,.5)
            end

            -- extract square patch
            local size = math.min(sample:size(2), sample:size(3))
            local t = math.floor((sample:size(2) - size)/2 + 1)
            local l = math.floor((sample:size(3) - size)/2 + 1)
            local b = t + size - 1
            local r = l + size - 1
            sample = sample[{ {},{t,b},{l,r} }]

            sample = image.scale(sample, w, h)

            -- extract sub-patch, with optional jitter:
            local size = math.min(sample:size(2), sample:size(3))
            local t = math.floor((sample:size(2) - h)/2 + 1)
            local l = math.floor((sample:size(3) - w)/2 + 1)
            --[[ if jitter > 0 and not test then
            t = t + math.floor(torch.uniform(-jitter/2,jitter/2))
            l = l + math.floor(torch.uniform(-jitter/2,jitter/2))
            end--]]
            local b = t + h - 1
            local r = l + w - 1
            sample = sample[{ {},{t,b},{l,r} }]

            -- save sample:
            samples[i+1] = sample

            -- normalize sample
            --print(global_std)

            for j = 1, c do
               samples[i+1][j]:add(-global_mean[j])
               samples[i+1][j]:div(global_std[j])
            end
            --a.a=a
            --samples[i+1]:div(global_std)

            if local_mean then
               local mean = samples[i+1]:mean()
               samples[i+1]:add(-mean)
            end

            if local_std then
               local std = samples[i+1]:std()
               samples[i+1]:div(std)
            end

            -- label:
            targets_p[i] = labels_p[ii]
         end

         -- reset com (tells the main thread that the batch is ready)
         com[0] = 0
      end
   end

   -- dispatch:
   local thread = llthreads.new(string.dump(block),
   nil,
   nsamples, bs, c, h, w,
   opt.distort,
   opt.jitter,
   opt.receptive,
   opt.gm,
   opt.lm,
   opt.ls,
   tonumber(ffi.cast('intptr_t', torch.data(shuffle))),
   tonumber(ffi.cast('intptr_t', torch.data(samples))),
   tonumber(ffi.cast('intptr_t', torch.data(targets))),
   tonumber(ffi.cast('intptr_t', torch.data(jpegs))),
   tonumber(ffi.cast('intptr_t', torch.data(offsets))),
   tonumber(ffi.cast('intptr_t', torch.data(sizes))),
   tonumber(ffi.cast('intptr_t', torch.data(labels))),
   tonumber(ffi.cast('intptr_t', com)),
   tonumber(ffi.cast('intptr_t', torch.data(global_mean))),
   tonumber(ffi.cast('intptr_t', torch.data(global_std)))
   )
   thread:start(true)

   -- keep references alive (the GC collects them otherwise,
   -- because it doesn't know that the thread needs them...)
   dataset.keep = {
      shuffle = shuffle,
      samples = samples,
      targets = targets,
      com = com,
      jpegs = jpegs,
      offsets = offsets,
      sizes = sizes,
      labels = labels,
   }

   -- prepare batch, asynchronously
   local function prepareBatch(idx, istest)
      -- request new batch!
      com[1] = (istest and 1) or 0
      com[0] = idx
   end

   -- copy batch to GPU
   local function copyBatch()
      -- wait on batch ready
      while tonumber(com[0]) > 0 do
         sys.sleep(.005)
      end

      if opt.cuda then

         -- move to CUDA
         samplesCUDA:copy(samples)
         targetsCUDA:copy(targets)
         return samplesCUDA, targetsCUDA

      else
         return samples:clone(), targets:clone()
      end

   end

   -- augment dataset:
   dataset.copyBatch = copyBatch
   dataset.prepareBatch = prepareBatch
   dataset.nbatches = nbatches

   return dataset

end

function prepare_sync(data_file, info_file, save_file, save_act)

   local data = load_raw_imagenet(data_file, info_file, save_file, save_act)

   local nsamples = data.data:size(1)
   local samples = torch.FloatTensor(opt.batchSize, data.data:size(2), data.data:size(3), data.data:size(4))
   local targets = torch.FloatTensor(opt.batchSize)
   local shuffle = torch.randperm(nsamples):type('torch.LongTensor')

   local samplesCUDA = {}
   local targetsCUDA = {}
   if opt.cuda then
      samplesCUDA = samples:clone():cuda()
      targetsCUDA = targets:clone():cuda()
   end

   data.keep = {
      shuffle = shuffle,
      samples = samples,
      targets = targets
   }

   -- prepare batch
   local function prepareBatch(idx, istest)

      local bs = opt.batchSize

      for i = 1, bs do

         local j = shuffle[(idx - 1) * bs + i]
         samples[i] = data.data[j]
         targets[i] = data.labels[j]

      end

      if opt.cuda then
         samplesCUDA:copy(samples)
         targetsCUDA:copy(targets)
      end

   end

   -- copy batch
   local function copyBatch()

      if opt.cuda then
         return samplesCUDA, targetsCUDA
      else
         return samples:clone(), targets:clone()
      end

   end

   local function nbatches()
      return math.floor(data.data:size(1) / opt.batchSize)
   end

   -- augment dataset:
   data.copyBatch = copyBatch
   data.prepareBatch = prepareBatch
   data.nbatches = nbatches

   return data

end

----------------------------------------------------------------------
--script for filtering imagenet
function create_imagenet_map(new_class, n)
   --maps imagenet classes to new class table
   --n - number of classes in imagenet

   --map
   local m = torch.Tensor(n, 2):zero()

   for i = 1, #new_class do
      local subclasses = new_class[i][2]
      for j = 1, #subclasses do
         local c = subclasses[j]
         --print(c)
         m[c][1] = i
         m[c][2] = j
      end
   end

   return m

end

function filter_imagenet(src_data, src_info, dst_data, dst_info, new_classes, imagenet_class_names, max_class_size)

   --load src data
   print('Loading src data')
   local d = torch.load(src_info)
   local jpegs = torch.ByteStorage(src_data)
   local t_jpegs = torch.ByteTensor(jpegs)

   --map imagent ids to new class table
   local map_imagenet_id = create_imagenet_map(new_classes, 1000)

   --calc size of new data
   print('Calculating size of new data')
   local new_data_size = 0 --size of all new images in bytes
   local new_data_n = 0 --number of images in new data
   local idxs = {} --imagenet indexes of new images
   local class_size = torch.Tensor(#new_classes):zero() --current number of photos in each class

   torch.manualSeed(1)
   local shuffle = torch.randperm(d.labels:size(1))

   for i = 1, d.labels:size(1) do

      xlua.progress(i, d.labels:size(1))

      local si = shuffle[i]
      local label = d.labels[si]
      local i1 = map_imagenet_id[label][1]

      if i1 > 0 and class_size[i1] < max_class_size then
         --image in new data

         new_data_n = new_data_n + 1
         new_data_size = new_data_size + d.sizes[si]
         table.insert(idxs, si)
         class_size[i1] = class_size[i1] + 1

      end

   end
   print('Number of samples: ' .. new_data_n .. ', data size: ' .. new_data_size)

   --allocate memory for new data
   print('Allocating memory')
   local new_data = {}
   new_data.labels = torch.LongTensor(new_data_n) --new labels
   new_data.imagenet_labels = torch.LongTensor(new_data_n) --imagenet labels
   new_data.sizes = torch.LongTensor(new_data_n) --new sizes
   new_data.offsets = torch.LongTensor(new_data_n) --new offsets
   local t_new_jpegs = torch.ByteTensor(new_data_size)

   --copy data
   print('Copy data')
   local offset = 1

   for i = 1, new_data_n do

      xlua.progress(i, new_data_n)

      local j = idxs[i]
      local imagenet_label = d.labels[j]
      new_data.labels[i] = map_imagenet_id[imagenet_label][1]
      new_data.imagenet_labels[i] = imagenet_label
      new_data.sizes[i] = d.sizes[j]
      new_data.offsets[i] = offset
      offset_old = offset
      offset = offset + new_data.sizes[i]

      t_new_jpegs[{{offset_old, offset - 1}}] = t_jpegs[{{d.offsets[j], d.offsets[j] + d.sizes[j] - 1}}]

   end

   --save data
   print('Saving data')
   torch.save(dst_data, torch.ByteTensor(new_data_size - 107))
   local mmjpegs = torch.ByteStorage(dst_data, true)
   mmjpegs:copy(t_new_jpegs:storage())

   torch.save(dst_info, new_data)

end

function save_images(ims, fname, w)
   --save several images in one file.

   local n = ims:size(1)
   local w = w or 600
   local pad = 4
   local nrow = math.floor(w / (opt.width + pad))
   local ncol = math.floor(n / nrow) + 2
   local h = (opt.height + pad) * ncol
   local im = torch.Tensor(3, h, w):zero()

   local x = 1
   local y = 1

   for k = 1, n do

      if x + opt.width + pad >= w then
         x = 1
         y = y + opt.height + pad
      end

      im[{{}, {y, y + opt.height - 1}, {x, x + opt.width - 1}}] = ims[k]
      x = x + opt.width + pad

   end

   image.save(fname, im)

end

function verify_data(data, classes, imagenet_class_names, folder)
   --saves data in separate folders. Each class in separate folder.

   --map imagent ids to new class table
   map_imagenet_id = create_imagenet_map(classes, 1000)

   --create new classes structure
   bd = {}
   for i = 1, #classes do

      --print(i)
      local subclasses = classes[i][2]
      bd[i] = {}
      bd[i].name = classes[i][1]
      bd[i].subclasses = {}

      for j = 1, #subclasses do

         local sc = {}
         sc.imagenet_id = subclasses[j]
         sc.imagenet_name = imagenet_class_names[sc.imagenet_id]
         sc.size = 0
         sc.current_image = 0
         bd[i].subclasses[j] = sc

      end

   end

   --calc number of images in each class
   print('Calc number of images in each class')
   for i = 1, data.labels:size(1) do

      xlua.progress(i, data.labels:size(1))
      local id = data.imagenet_labels[i]
      local i1 = map_imagenet_id[id][1]
      local i2 = map_imagenet_id[id][2]
      if i1 > 0 then
         bd[i1].subclasses[i2].size = bd[i1].subclasses[i2].size + 1
      end

   end

   --create tensors for images
   for i = 1, #classes do
      local subclasses = bd[i].subclasses
      for j = 1, #subclasses do

         bd[i].subclasses[j].images = torch.Tensor(bd[i].subclasses[j].size, 3, opt.height, opt.width):zero()
      end
   end

   --copy images
   print('Copy images')
   for i = 1, data.labels:size(1) do

      xlua.progress(i, data.labels:size(1))
      local id = data.imagenet_labels[i]
      local i1 = map_imagenet_id[id][1]
      local i2 = map_imagenet_id[id][2]
      if i1 > 0 then
         local j = bd[i1].subclasses[i2].current_image + 1
         bd[i1].subclasses[i2].images[j] = data.data[i]
         bd[i1].subclasses[i2].current_image  = j
      end

   end

   --save to folder
   print('Saving images')
   os.execute('mkdir -p ' .. folder)
   for i = 1, #bd do

      xlua.progress(i, #bd)
      local class_folder = folder .. i .. '_' .. bd[i].name
      os.execute('mkdir -p ' .. class_folder)
      local subclasses = bd[i].subclasses

      for j = 1, #(bd[i].subclasses) do

         --  print(i .. ' ' .. j)
         if bd[i].subclasses[j].size > 0 then

            local fname = class_folder .. '/' .. j .. '_' .. subclasses[j].imagenet_name .. '_' .. subclasses[j].imagenet_id ..'.jpg'
            save_images(bd[i].subclasses[j].images, fname)

         end

      end

   end

end

function show_classes(data, k, class_names)

   local k = k or 100
   local ivch = data.data:size(2)
   local ivhe = data.data:size(3)
   local ivwi = data.data:size(4)

   local disp_ims = {}
   local nclasses = #class_names

   local nims = torch.Tensor(nclasses)

   for i = 1, nclasses do
      disp_ims[i] = torch.Tensor(k, ivch, ivhe, ivwi)
      nims[i] = 0
   end

   local ok = 0
   local i = 0

   while (ok < nclasses) and (i < data.data:size(1)) do

      i = i + 1
      local cl = data.labels[i]

      if (nims[cl] < k) then

         nims[cl] = nims[cl] + 1
         disp_ims[cl][nims[cl]] = data.data[i]
         if nims[cl] == k then
            ok = ok + 1
         end

      end

   end

   for i = 1, nclasses do
      disp_ims[i] = disp_ims[i][{{1, nims[i]}}]
   end

   for i = 1, nclasses do
      image.display({ image = disp_ims[i], legend = class_names[i], padding=4 })
   end

end
-----------------------------------------------------------------------------

function csv2table(csv_file, out_file)
   --convert class names from csv file to lua table

   local csv = require 'csv'
   torch.setdefaulttensortype('torch.FloatTensor')

   local class_names = {}

   -- load csv
   local f = csv.open(csv_file)

   for fields in f:lines() do

      i = tonumber(fields[1])
      if i then
         label = fields[3]
         class_names[i] = label
      else
         print 'skip'
      end

   end

   -- save tables
   torch.save(out_file, class_names)
   print('==> Saved ' .. out_file)

end

function nilling(module)
   module.gradBias   = nil
   if module.finput then module.finput = torch.Tensor() end
   module.gradWeight = nil
   module.output     = torch.Tensor()
   module.fgradInput = nil
   module.gradInput  = nil
end

function netLighter(network)
   nilling(network)
   if network.modules then
      for _,a in ipairs(network.modules) do
         netLighter(a)
      end
   end
end

function saveNet(model, filename, verbose)
   --   local filename = paths.concat(opt. name)
   if verbose then
      print('==> saving model to '..filename)
   end
   modelToSave = model:clone()
   netLighter(modelToSave)
   torch.save(filename, modelToSave)
end
