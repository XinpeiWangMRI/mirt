 function [xs, info] = ir_denoise_admm1(yi, varargin)
%function [xs, info] = ir_denoise_admm1(yi, varargin)
%|
%| Image denoising by cost function
%| cost(x) 1/2 | y - x |_2^2 + beta * pot(C x)
%| minimized via ADMM algorithm (cf split Bregman) with v = C x split.
%|
%| in
%|	yi	[(N)]		noisy data
%|
%| options
%|	x0	[(N)]		initial estimate
%|	C			penalty matrix
%|				(default: circulant h,v finite differences)
%|	shrink			shrink function for pot: shrink(x, reg)
%|				(default: l1, soft thresholding)
%|
%|	niter			# total iterations (default: 1)
%|					(max # if tol used)
%|	isave	[]		list of iterations to archive (default: 'last')
%|	userfun	@		user defined function handle (see default below)
%|					taking arguments (x, iter, userarg{:})
%|	userarg {}		user arguments to userfun (default {})
%|	stop_diff_tol		stop iterations if norm(xnew-xold)/norm(xnew)
%|				is less than this unitless value.  default: 0
%|	stop_diff_norm		use norm(., type) for stop rule
%|				choices: 1 | 2 (default) | inf
%|	chat	0|1		verbosity (default 0)
%|
%| out
%|	xs	[(N) niter]	estimates each iteration
%|	info	[niter 1]	time each iteration (for default userfun)
%|
%| Copyright 2013-02-25, Jeff Fessler, University of Michigan

if nargin < 1, help(mfilename), error(mfilename), end
if nargin == 1 && streq(yi, 'test'), ir_denoise_admm1_test, return, end

% defaults
arg.x0 = yi;
arg.C = [];
arg.beta = 1; % regularization parameter
arg.shrink = [];
arg.rho = 1; % AL penalty parameter

arg.niter = 1;
arg.isave = [];
arg.userfun = @userfun_default;
arg.userarg = {};
arg.stop_diff_tol = 0;
arg.stop_diff_norm = 2;
arg.chat = 0;

arg = vararg_pair(arg, varargin);

x = arg.x0;

if isempty(arg.C)
	if ndims(x) > 2, fail 'not done', end
	C = Cdiffs(size(x), 'type_diff', 'circshift', ...
		'offsets', '2d:hv');
%		'offsets', eye(ndims(x));
elseif streq(arg.C, 'sep1') % separable
	arg.Ch = Cdiffs(size(x,1), 'type_diff', 'circshift', 'offsets', 1);
	arg.Cv = Cdiffs(size(x,2), 'type_diff', 'circshift', 'offsets', 1);
	C = fatrix2('arg', arg, 'idim', size(x), 'odim', size(x), ...
		'forw', @(arg, x) arg.Ch * x * arg.Cv, ...
		'back', @(arg, y) arg.Ch' * y * arg.Cv');
%	test_adjoint(C, 'big', 1)
%	fatrix2_tests(C)

else
	C = arg.C;
end

if isempty(arg.shrink)
	tmp = potential_fun('l1', 1);
	shrink = @(z, reg) tmp.shrink(z, reg);
else
	shrink = arg.shrink;
end

arg.isave = iter_saver(arg.isave, arg.niter);
if arg.stop_diff_tol
	norm_diff = @(x) norm(x(:), arg.stop_diff_norm);
end

cpu etic

np = numel(x);
xs = zeros(np, length(arg.isave));
if any(arg.isave == 0)
	xs(:, arg.isave == 0) = x(:);
end

% precompute DFT-based inverse of (I + rho C'C)
e = zeros(size(x)); e(1) = 1;
psf = e + arg.rho * (C' * (C * e));
dft = fftn(psf);
dft = reale(dft); dft = max(dft,0); % ensure positive semidefinite
if arg.chat
	im(fftshift(psf))
	im(fftshift(dft))
	printm('cond = %g', max(dft(:)) / min(dft(:)))
end
Q = Gdft('mask', true(size(x)));
Q = (1 / sqrt(prod(size(x)))) * Q;
Inv = Q' * Gdiag(1 ./ dft) * Q;

vv = C * x;
eta = 0;

rho = arg.rho;
beta = arg.beta;

% iterate
for iter = 1:arg.niter
	ticker(mfilename, iter, arg.niter)

	xp = x; % previous

	% update primal
	tmp = yi + rho * (C' * (vv + eta));
	x = Inv * tmp;

	% update auxiliary
	tmp = C * x - eta;
	vv = shrink(tmp, beta / rho);

	% update multiplier
	tmp = C * x - vv;
	eta = eta - tmp;

	if any(arg.isave == iter)
		xs(:, arg.isave == iter) = x(:);
	end
	info(iter,:) = arg.userfun(x, iter, arg.userarg{:});

	% check norm(xnew-xold) / norm(xnew) vs threshold
	if iter > 1 && arg.stop_diff_tol
		ratio = norm_diff(x - xp) / norm_diff(x);
		if ratio < arg.stop_diff_tol
			if 1 || arg.chat
				printm('stop at iteration %d, diff %g < %g', ...
					iter, ratio, arg.stop_diff_tol)
			end
			if isequal(arg.isave, arg.niter) % saving only last?
				xs = x(:); % save the 'final' iterate
			else % saving many iterates?
				xs(:, arg.isave > iter) = []; % clear out unused
			end
		break
		end
	end
end

xs = reshapee(xs, size(x), []); % [(N) niter]


% default user function.
% using this evalin('caller', ...) trick, one can compute anything of interest
function out = userfun_default(x, iter, varargin)
%pr minmax(x)
out = [cpu('etoc')];
