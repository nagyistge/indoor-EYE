-------------------------------------------------------------------------------
--Functions for training and testing a classifier
--Artem Kuharenko
-------------------------------------------------------------------------------

require 'torch'   -- torch
require 'optim'   -- an optimization package, for online and batch methods

function train(data, model, loss)
--train one iteration

   data.prepareBatch(1)
   
   for t = 1, data.nbatches() do

      xlua.progress(t, data.nbatches())

--      local t0 = sys.clock()
      --copy batch
      ims, targets = data.copyBatch()
      
      --prepare next batch      
      if t < data.nbatches() then 
         data.prepareBatch(t + 1)
      end
--      print('load data: ' .. sys.clock() - t0)

      -- create closure to evaluate f(X) and df/dX
      local eval_E = function(w)

         dE_dw:zero()

         local y = model:forward(ims)
         local E = loss:forward(y, targets)
         ce_train_error = ce_train_error + E * opt.batchSize

         local dE_dy = loss:backward(y, targets)
         model:backward(ims, dE_dy)

         for i = 1, opt.batchSize do
            train_confusion:add(y[i], targets[i])
         end

         return E, dE_dw

      end

      -- optimize on current mini-batch
      optim.sgd(eval_E, w, optimState)

   end

   ce_train_error = ce_train_error / (data.nbatches() * opt.batchSize)

end

function test(data, model, loss)

   for t = 1, data.nbatches() do

      xlua.progress(t, data.nbatches())
      data.prepareBatch(t)
      ims, targets = data.copyBatch()

      -- test sample
      local preds = model:forward(ims)

      -- confusion
      for i = 1, opt.batchSize do

         test_confusion:add(preds[i], targets[i])
         local E = loss:forward(preds[i], targets[i])
         ce_test_error = ce_test_error + E

      end

   end

   ce_test_error = ce_test_error / (data.nbatches() * opt.batchSize)

end

--reduced version of optim.ConfusionMatrix:__tostring__
function print_confusion_matrix(self, init_str)

   self:updateValids()
   local str = {init_str}

   if opt.print_confusion_matrix then

      str = {init_str .. ' ConfusionMatrix:\n'}
      local nclasses = self.nclasses
      table.insert(str, '[')
      for t = 1,nclasses do
         local pclass = self.valids[t] * 100
         pclass = string.format('%2.3f', pclass)
         if t == 1 then
            table.insert(str, '[')
         else
            table.insert(str, ' [')
         end
         for p = 1,nclasses do
            table.insert(str, string.format('%' .. opt.confusion_matrix_tab .. 'd', self.mat[t][p]))
         end
         if self.classes and self.classes[1] then
            if t == nclasses then
               table.insert(str, ']]  ' .. pclass .. '% \t[class: ' .. (self.classes[t] or '') .. ']\n')
            else
               table.insert(str, ']   ' .. pclass .. '% \t[class: ' .. (self.classes[t] or '') .. ']\n')
            end
         else
            if t == nclasses then
               table.insert(str, ']] ' .. pclass .. '% \n')
            else
               table.insert(str, ']   ' .. pclass .. '% \n')
            end
         end
      end

      
   end
     
   table.insert(str, string.format(' accuracy: %.3f', self.totalValid*100) .. '%')
   print(table.concat(str))

end

function train_and_test(trainData, testData, model, loss, plot, verbose)

   if verbose then
      print '==> training neuralnet'
   end
   w, dE_dw = model:getParameters()

	--init confusion matricies
   train_confusion = optim.ConfusionMatrix(classes)
   test_confusion = optim.ConfusionMatrix(classes)
   train_confusion:zero()
   test_confusion:zero()

	--set optimization parameters
   optimState = {
      learningRate = opt.learningRate,
      momentum = opt.momentum,
      weightDecay = opt.weightDecay,
      learningRateDecay = opt.learningRateDecay
   }

	--get image size
   local ivch = trainData.data:size(2)
   local ivhe = trainData.data:size(3)
   local ivwi = trainData.data:size(4)

	--init logger for train and test accuracy	
   local logger = optim.Logger(opt.save_dir .. 'logger.log')
	--init logger for train and test cross-entropy error   
	local ce_logger = optim.Logger(opt.save_dir .. 'celogger.log')

	--allocate memory for batch of images
   ims = torch.Tensor(opt.batchSize, ivch, ivhe, ivwi)
	--allocate memory for batch of labels
   targets = torch.Tensor(opt.batchSize)

   if opt.type == 'cuda' then 
      ims = ims:cuda()
      targets = targets:cuda()
   end

   for i = 1, opt.niters do

		-------------------------------------------------------------------------------
		--train
      local time = sys.clock()

      ce_train_error = 0
      if verbose then print('==> Train ' .. i) end
      train(trainData, model, loss)
      
		time = sys.clock() - time

      if verbose then
         print(string.format("======> Time to learn 1 iteration = %.2f sec", time))
         print(string.format("======> Time to train 1 sample = %.2f ms", time / trainData.data:size(1) * 1000))
         print(string.format("======> Train CE error: %.2f", ce_train_error))         
         print_confusion_matrix(train_confusion, '======> Train')
         print('\n')
      else
         xlua.progress(i, opt.niters)
      end
		-------------------------------------------------------------------------------

		-------------------------------------------------------------------------------
		--test
      local time = sys.clock()
      ce_test_error = 0
      if verbose then print('==> Test ' .. i) end
      test(testData, model, loss)
      time = sys.clock() - time

      if verbose then
         print(string.format("======> Time to test 1 iteration = %.2f sec", time))
         print(string.format("======> Time to test 1 sample = %.2f ms", time / testData.data:size(1) * 1000))
         print(string.format("======> Test CE error: %.2f", ce_test_error))         
         print_confusion_matrix(test_confusion, '======> Test')
         print('\n')
      end
		-------------------------------------------------------------------------------

      -- update loggers
      train_confusion:updateValids()
      test_confusion:updateValids()
      logger:add{['% train accuracy'] = train_confusion.totalValid * 100, ['% test accuracy'] = test_confusion.totalValid * 100}
      ce_logger:add{['ce train error'] = ce_train_error, ['ce test error'] = ce_test_error}

		--plot
      if plot then
         logger:style{['% train accuracy'] = '-', ['% test accuracy'] = '-'}
         logger:plot()
         ce_logger:style{['ce train error'] = '-', ['ce test error'] = '-'}
         ce_logger:plot()
      end

		--save classifier every 5 iterations
      if (i % 5 == 0) then
         saveNet(model, opt.save_dir .. 'classifier-' .. i .. '.net', verbose)
      end

      train_confusion:zero()
      test_confusion:zero()

   end

	-------------------------------------------------------------------------------
	--compute train and test accuracy. Average over last 5 iterations 
   local test_accs = logger.symbols['% test accuracy']
   local train_accs = logger.symbols['% train accuracy']
   local test_acc = 0
   local train_acc = 0
   
	for i = 0, 4 do
      test_acc = test_acc + test_accs[#test_accs - i]
      train_acc = train_acc + train_accs[#train_accs - i]
   end

   test_acc = test_acc / 5
   train_acc = train_acc / 5

   if verbose then
      print('final train accuracy = ' .. train_acc)
      print('final test accuracy = ' .. test_acc)
   end
	-------------------------------------------------------------------------------

   return train_acc, test_acc

end